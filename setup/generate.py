"""Deterministic seed generator.

Emits CSV files to raw/, builds them as DuckDB tables in warehouse.duckdb
under schema `raw`, and renders DATA-123.md from DATA-123.md.tmpl with the
canonical reconciliation number.

Run via `make setup` (which also runs dbt full-refresh after this).
"""

from __future__ import annotations

import argparse
import csv
import random
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import duckdb
from faker import Faker

ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "raw"
DB_PATH = ROOT / "warehouse.duckdb"
TEMPLATE_PATH = ROOT / "DATA-123.md.tmpl"
TICKET_PATH = ROOT / "DATA-123.md"

SEED = 20260517
START_DATE = datetime(2024, 11, 1)
END_DATE = datetime(2026, 5, 1)  # 18 months

N_MERCHANTS = 5_000
N_PRODUCTS = 500
N_ORDERS = 10_000

CUSTOMER_TYPES = ["B2B", "B2C", "MKT"]
TIERS = ["STD", "ENT", "PLT"]


def random_dt(rng: random.Random, start: datetime, end: datetime) -> datetime:
    delta = end - start
    seconds = rng.randint(0, int(delta.total_seconds()))
    return start + timedelta(seconds=seconds)


def write_csv(name: str, header: list[str], rows: list[list]) -> None:
    RAW_DIR.mkdir(exist_ok=True)
    path = RAW_DIR / f"{name}.csv"
    with path.open("w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)


def gen_merchants(rng: random.Random, fake: Faker) -> list[list]:
    rows = []
    for i in range(1, N_MERCHANTS + 1):
        rows.append([
            f"M{i:05d}",
            fake.company(),
            rng.choice(CUSTOMER_TYPES),
            rng.choice(TIERS),
            random_dt(rng, START_DATE - timedelta(days=365), START_DATE).isoformat(),
        ])
    return rows


def gen_products(rng: random.Random, fake: Faker) -> list[list]:
    rows = []
    for i in range(1, N_PRODUCTS + 1):
        rows.append([
            f"P{i:04d}",
            fake.catch_phrase(),
            rng.randint(500, 50_000),  # list_price_in_cents
        ])
    return rows


@dataclass
class Order:
    order_id: str
    merchant_id: str
    customer_id: str
    order_status: str
    is_test: str           # "" (NULL) | "true" | "false"
    ordered_at: datetime
    paid_at: datetime | None
    shape: str             # "single" | "multi_full" | "partial" | "pending" | "cancelled"


@dataclass
class LineItem:
    line_item_id: str
    order_id: str
    product_id: str
    quantity: int
    unit_price_in_cents: int
    line_status: str


@dataclass
class Shipment:
    shipment_id: str
    order_id: str
    shipped_at: datetime


@dataclass
class ShipmentLineItem:
    shipment_line_item_id: str
    shipment_id: str
    line_item_id: str
    quantity_shipped: int


@dataclass
class RefundPlan:
    merchant_id: str
    pattern: str


def pick_refund_merchants(rng: random.Random, orders: list[Order]) -> list[RefundPlan]:
    """Assign each merchant in turn to the next refund pattern in the rotation.
    Picks lowest-numbered merchants that have enough eligible orders."""
    eligible: dict[str, int] = {}
    for o in orders:
        if o.order_status in ("shipped", "partially_shipped") and o.is_test != "true":
            eligible[o.merchant_id] = eligible.get(o.merchant_id, 0) + 1

    sorted_ids = sorted(eligible.keys())
    multi = [m for m in sorted_ids if eligible[m] >= 2]
    single = [m for m in sorted_ids if eligible[m] >= 1]

    used: set[str] = set()
    result = []
    for pattern, pool in [
        ("shopify_only", single),
        ("stripe_only", single),
        ("internal_pos_only", single),
        ("shopify_stripe", multi),
        ("none", sorted_ids),
    ]:
        mid = next((m for m in pool if m not in used), pool[0] if pool else sorted_ids[0])
        used.add(mid)
        result.append(RefundPlan(mid, pattern))
    return result


def gen_orders_and_lines(
    rng: random.Random,
    products: list[list],
) -> tuple[list[Order], list[LineItem]]:
    """Generate orders + their line items. line_status defaults to 'pending' for
    pending/cancelled shapes; Task 5b overwrites it for shipped/partial shapes."""
    product_prices = {p[0]: p[2] for p in products}
    product_ids = list(product_prices.keys())

    orders: list[Order] = []
    lines: list[LineItem] = []
    next_line_id = 1

    for i in range(1, N_ORDERS + 1):
        order_id = f"O{i:06d}"
        merchant_id = f"M{rng.randint(1, N_MERCHANTS):05d}"
        customer_id = f"C{rng.randint(1, N_MERCHANTS * 4):06d}"

        # is_test: ~95% NULL (empty), ~3% true, ~2% false
        r = rng.random()
        if r < 0.95:
            is_test = ""
        elif r < 0.98:
            is_test = "true"
        else:
            is_test = "false"

        ordered_at = random_dt(rng, START_DATE, END_DATE - timedelta(days=14))

        s = rng.random()
        if s < 0.70:
            shape = "single"
        elif s < 0.82:
            shape = "multi_full"
        elif s < 0.90:
            shape = "partial"
        elif s < 0.95:
            shape = "pending"
        else:
            shape = "cancelled"

        # Order-level status + paid_at
        if shape == "cancelled":
            order_status = "cancelled"
            paid_at = None
            default_line_status = "cancelled"
        elif shape == "pending":
            order_status = "pending"
            paid_at = ordered_at + timedelta(minutes=rng.randint(1, 120))
            default_line_status = "pending"
        elif shape == "partial":
            order_status = "partially_shipped"
            paid_at = ordered_at + timedelta(minutes=rng.randint(1, 120))
            default_line_status = "pending"  # Task 5b overwrites per-line
        else:  # single, multi_full
            order_status = "shipped"
            paid_at = ordered_at + timedelta(minutes=rng.randint(1, 120))
            default_line_status = "fulfilled"  # Task 5b confirms

        # 1–4 line items per order, weighted toward 1–2
        n_lines = rng.choices([1, 2, 3, 4], weights=[40, 35, 20, 5])[0]
        for _ in range(n_lines):
            li_id = f"L{next_line_id:07d}"
            next_line_id += 1
            pid = rng.choice(product_ids)
            qty = rng.randint(1, 5)
            # unit_price = list_price * uniform(0.85, 1.0) — revenue isn't purely list price
            unit_price = int(product_prices[pid] * rng.uniform(0.85, 1.0))
            lines.append(LineItem(li_id, order_id, pid, qty, unit_price, default_line_status))

        orders.append(Order(
            order_id=order_id,
            merchant_id=merchant_id,
            customer_id=customer_id,
            order_status=order_status,
            is_test=is_test,
            ordered_at=ordered_at,
            paid_at=paid_at,
            shape=shape,
        ))

    return orders, lines


def gen_shipments(
    rng: random.Random,
    orders: list[Order],
    lines: list[LineItem],
) -> tuple[list[Shipment], list[ShipmentLineItem]]:
    """Build shipments + shipment_line_items per the per-order shape. Mutates
    lines[].line_status where the shape implies a non-default status (partials).
    Enforces invariant: sum(quantity_shipped per line) ≤ line.quantity."""
    lines_by_order: dict[str, list[LineItem]] = {}
    for li in lines:
        lines_by_order.setdefault(li.order_id, []).append(li)

    shipments: list[Shipment] = []
    ship_lines: list[ShipmentLineItem] = []
    next_ship_id = 1
    next_ship_line_id = 1

    for o in orders:
        if o.shape in ("pending", "cancelled"):
            continue  # no shipments

        order_lines = lines_by_order[o.order_id]

        if o.shape == "single":
            ship_dt = o.ordered_at + timedelta(days=rng.randint(1, 14))
            sid = f"S{next_ship_id:07d}"
            next_ship_id += 1
            shipments.append(Shipment(sid, o.order_id, ship_dt))
            for li in order_lines:
                ship_lines.append(ShipmentLineItem(
                    f"SL{next_ship_line_id:08d}", sid, li.line_item_id, li.quantity
                ))
                next_ship_line_id += 1
                li.line_status = "fulfilled"

        elif o.shape == "multi_full":
            # 2–3 shipments. First: 1–14 days; subsequent: 15–60 days after first.
            # 15–60 day gap forces month-boundary spread for many cases.
            ship_count = rng.choice([2, 3])
            first_dt = o.ordered_at + timedelta(days=rng.randint(1, 14))
            ship_dts = [first_dt]
            for _ in range(ship_count - 1):
                ship_dts.append(first_dt + timedelta(days=rng.randint(15, 60)))
            ship_dts = [min(d, END_DATE) for d in ship_dts]
            sids = []
            for dt in ship_dts:
                sid = f"S{next_ship_id:07d}"
                next_ship_id += 1
                sids.append(sid)
                shipments.append(Shipment(sid, o.order_id, dt))

            for li in order_lines:
                # Split qty across shipments. Last shipment takes the remainder.
                remaining = li.quantity
                for k, sid in enumerate(sids):
                    if k == len(sids) - 1:
                        take = remaining
                    else:
                        take = rng.randint(0, remaining)
                    if take > 0:
                        ship_lines.append(ShipmentLineItem(
                            f"SL{next_ship_line_id:08d}", sid, li.line_item_id, take
                        ))
                        next_ship_line_id += 1
                        remaining -= take
                li.line_status = "fulfilled"

        else:  # partial
            ship_dt = o.ordered_at + timedelta(days=rng.randint(1, 14))
            sid = f"S{next_ship_id:07d}"
            next_ship_id += 1
            shipments.append(Shipment(sid, o.order_id, ship_dt))

            for li in order_lines:
                pick = rng.choice(["full", "part", "pending"])
                if pick == "full":
                    ship_lines.append(ShipmentLineItem(
                        f"SL{next_ship_line_id:08d}", sid, li.line_item_id, li.quantity
                    ))
                    next_ship_line_id += 1
                    li.line_status = "fulfilled"
                elif pick == "part" and li.quantity > 1:
                    take = li.quantity - 1
                    ship_lines.append(ShipmentLineItem(
                        f"SL{next_ship_line_id:08d}", sid, li.line_item_id, take
                    ))
                    next_ship_line_id += 1
                    li.line_status = "pending"  # not fully fulfilled
                else:
                    # "pending" pick OR single-qty falling into "part" — leave unshipped
                    li.line_status = "pending"

    return shipments, ship_lines


def gen_refunds(rng: random.Random, plans: list[RefundPlan],
                orders: list[Order], lines: list[LineItem]) -> tuple[
    list[list], list[list], list[list], list[tuple[str, str, dict]]
]:
    """Generate refunds across 3 sources. Returns (shopify, stripe, internal_pos, notable_log).

    notable_log entries are (order_id, code, payload) — opaque tokens; the
    human-readable mapping lives in the interviewer-only renderer."""
    by_merchant: dict[str, list[Order]] = {}
    for o in orders:
        # is_test is "" (NULL) | "true" | "false" — treat anything except "true" as non-test
        if o.order_status in ("shipped", "partially_shipped") and o.is_test != "true":
            by_merchant.setdefault(o.merchant_id, []).append(o)
    by_order: dict[str, list[LineItem]] = {}
    for li in lines:
        by_order.setdefault(li.order_id, []).append(li)

    shopify_rows = []
    stripe_rows = []
    pos_rows = []
    notable_log: list[tuple[str, str, dict]] = []

    next_event_id = 1

    def order_total_cents(o: Order) -> int:
        return sum(li.quantity * li.unit_price_in_cents for li in by_order.get(o.order_id, []))

    for plan in plans:
        candidates = by_merchant.get(plan.merchant_id, [])
        if not candidates:
            continue

        n_refunds = max(1, int(len(candidates) * 0.05)) if plan.pattern != "none" else 0
        if plan.pattern == "shopify_stripe":
            n_refunds = min(max(2, n_refunds), 30)
        sampled = rng.sample(candidates, min(n_refunds, len(candidates)))

        for idx, o in enumerate(sampled):
            order_lines = by_order[o.order_id]
            total = order_total_cents(o)
            if total == 0:
                continue
            refunded_at = o.ordered_at + timedelta(days=rng.randint(7, 60))

            if plan.pattern == "shopify_only":
                target = rng.choice(order_lines)
                partial_roll = rng.random()
                if idx == 0:
                    plant_target = next(
                        (li for li in order_lines if li.quantity > 1), None
                    )
                    if plant_target is not None:
                        qty = 1
                        amt = qty * plant_target.unit_price_in_cents
                        notable_log.append((o.order_id, "P_QTY", {"qty": plant_target.quantity}))
                        shopify_rows.append([
                            f"SHF{next_event_id:06d}", o.order_id, plant_target.line_item_id,
                            qty, amt, refunded_at.isoformat()
                        ])
                        next_event_id += 1
                        continue
                if partial_roll < 0.2 and target.quantity > 1:
                    qty = 1
                    notable_log.append((o.order_id, "P_QTY", {"qty": target.quantity}))
                else:
                    qty = target.quantity
                amt = qty * target.unit_price_in_cents
                shopify_rows.append([
                    f"SHF{next_event_id:06d}", o.order_id, target.line_item_id,
                    qty, amt, refunded_at.isoformat()
                ])
                next_event_id += 1

            elif plan.pattern == "stripe_only":
                stripe_rows.append([
                    f"STR{next_event_id:06d}", o.order_id, "card",
                    total, refunded_at.isoformat()
                ])
                next_event_id += 1

            elif plan.pattern == "internal_pos_only":
                pos_rows.append([
                    f"POS{next_event_id:06d}", o.order_id, total, refunded_at.isoformat()
                ])
                next_event_id += 1
                if idx == 0:
                    notable_log.append((o.order_id, "P_POS", {}))

            elif plan.pattern == "shopify_stripe":
                target = rng.choice(order_lines)
                qty = target.quantity
                amt = qty * target.unit_price_in_cents
                shopify_rows.append([
                    f"SHF{next_event_id:06d}", o.order_id, target.line_item_id,
                    qty, amt, refunded_at.isoformat()
                ])
                next_event_id += 1

                if idx < 2:
                    half = amt // 2
                    stripe_rows.append([
                        f"STR{next_event_id:06d}", o.order_id, "card",
                        half, refunded_at.isoformat()
                    ])
                    next_event_id += 1
                    stripe_rows.append([
                        f"STR{next_event_id:06d}", o.order_id, "store_credit",
                        amt - half, refunded_at.isoformat()
                    ])
                    next_event_id += 1
                    notable_log.append((o.order_id, "P_SPLIT",
                        {"amt": amt, "half": half, "rest": amt - half}))
                else:
                    stripe_rows.append([
                        f"STR{next_event_id:06d}", o.order_id, "card",
                        amt, refunded_at.isoformat()
                    ])
                    next_event_id += 1

    return shopify_rows, stripe_rows, pos_rows, notable_log


def load_duckdb() -> None:
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = duckdb.connect(str(DB_PATH))
    con.execute("create schema if not exists raw")
    csv_tables = [
        "merchants", "products",
        "orders", "line_items", "shipments", "shipment_line_items",
        "refunds_shopify", "refunds_stripe", "refunds_internal_pos",
    ]
    for name in csv_tables:
        path = (RAW_DIR / f"{name}.csv").as_posix()
        con.execute(
            f"create or replace table raw.{name} as "
            f"select * from read_csv_auto('{path}', header=true)"
        )
    con.close()


def compute_reconciliation_amount(con: duckdb.DuckDBPyConnection) -> tuple[float, float]:
    """Returns (total_revenue_all_orders, total_revenue_non_test_orders) in dollars."""
    total_all = con.execute("""
        select sum(quantity * unit_price_in_cents) / 100.0
        from raw.line_items
    """).fetchone()[0]
    total_non_test = con.execute("""
        select sum(li.quantity * li.unit_price_in_cents) / 100.0
        from raw.line_items li
        join raw.orders o on o.order_id = li.order_id
        where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
    """).fetchone()[0]
    return float(total_all), float(total_non_test)


def render_ticket(non_test_amount: float) -> None:
    if not TEMPLATE_PATH.exists():
        raise FileNotFoundError(f"missing template: {TEMPLATE_PATH}")
    body = TEMPLATE_PATH.read_text()
    body = body.replace("{{ NON_TEST_REVENUE }}", f"{non_test_amount:,.2f}")
    TICKET_PATH.write_text(body)


def _try_write_interviewer_key(
    mismatch_log: list[tuple[str, str]],
    refund_log: list[tuple[str, str, dict]],
    reconciliation_amount: float,
) -> None:
    """Dynamically invoke the interviewer-only renderer when it ships with the
    repo. The handoff workflow removes `docs/interviewer/` before sending the
    repo to a candidate, so this no-ops cleanly on the candidate's machine."""
    import importlib.util

    module_path = ROOT / "docs" / "interviewer" / "_answer_key.py"
    out_path = ROOT / "docs" / "interviewer" / "answer-key.md"
    if not module_path.exists():
        return
    spec = importlib.util.spec_from_file_location("_interviewer_answer_key", module_path)
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.write_answer_key(out_path, mismatch_log, refund_log, reconciliation_amount)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Skip CSV regeneration; build DuckDB and render ticket from existing raw/*.csv.",
    )
    args = parser.parse_args()

    if args.build_only:
        missing = [
            name for name in (
                "merchants", "products",
                "orders", "line_items", "shipments", "shipment_line_items",
                "refunds_shopify", "refunds_stripe", "refunds_internal_pos",
            ) if not (RAW_DIR / f"{name}.csv").exists()
        ]
        if missing:
            raise FileNotFoundError(
                f"--build-only requires existing raw/*.csv; missing: {missing}. "
                f"Run `make seed` to regenerate."
            )

        print("build-only mode: skipped CSV regeneration")
        print("loading DuckDB warehouse...")
        load_duckdb()

        con = duckdb.connect(str(DB_PATH), read_only=True)
        try:
            total_all, total_non_test = compute_reconciliation_amount(con)
        finally:
            con.close()

        print(f"reconciliation: total ${total_all:,.2f} | non-test ${total_non_test:,.2f}")

        render_ticket(total_non_test)
        # Skip answer-key regen: committed answer-key.md is in sync with committed CSVs.
        print("done.")
        return

    rng = random.Random(SEED)
    fake = Faker()
    Faker.seed(SEED)

    print("generating merchants...")
    write_csv(
        "merchants",
        ["merchant_id", "merchant_name", "customer_type", "tier", "merchant_created_at"],
        gen_merchants(rng, fake),
    )

    print("generating products...")
    write_csv(
        "products",
        ["product_id", "product_name", "list_price_in_cents"],
        gen_products(rng, fake),
    )

    print("generating orders + line items...")
    products_rows = []
    with (RAW_DIR / "products.csv").open() as f:
        reader = csv.reader(f)
        next(reader)
        for row in reader:
            products_rows.append([row[0], row[1], int(row[2])])
    orders, lines = gen_orders_and_lines(rng, products_rows)

    write_csv(
        "orders",
        ["order_id", "merchant_id", "customer_id", "order_status", "is_test",
         "ordered_at", "paid_at"],
        [[o.order_id, o.merchant_id, o.customer_id, o.order_status, o.is_test,
          o.ordered_at.isoformat(),
          o.paid_at.isoformat() if o.paid_at else ""] for o in orders],
    )
    write_csv(
        "line_items",
        ["line_item_id", "order_id", "product_id", "quantity",
         "unit_price_in_cents", "line_status"],
        [[li.line_item_id, li.order_id, li.product_id, li.quantity,
          li.unit_price_in_cents, li.line_status] for li in lines],
    )

    print("generating shipments...")
    shipments, ship_lines = gen_shipments(rng, orders, lines)

    mismatch_log: list[tuple[str, str]] = []
    candidate_indices = [i for i, o in enumerate(orders) if o.order_status == "shipped"][:7]
    for idx, order_idx in enumerate(candidate_indices):
        o = orders[order_idx]
        first_line_idx = next(j for j, li in enumerate(lines) if li.order_id == o.order_id)
        if idx % 2 == 0:
            lines[first_line_idx].line_status = "cancelled"
            mismatch_log.append((o.order_id, "M_A"))
        else:
            orders[order_idx].order_status = "partially_cancelled"
            mismatch_log.append((o.order_id, "M_B"))

    # Re-write orders + line_items since gen_shipments and the mismatch loop
    # above may have mutated order_status / line_status after the initial writes.
    write_csv(
        "orders",
        ["order_id", "merchant_id", "customer_id", "order_status", "is_test",
         "ordered_at", "paid_at"],
        [[o.order_id, o.merchant_id, o.customer_id, o.order_status, o.is_test,
          o.ordered_at.isoformat(),
          o.paid_at.isoformat() if o.paid_at else ""] for o in orders],
    )
    write_csv(
        "line_items",
        ["line_item_id", "order_id", "product_id", "quantity",
         "unit_price_in_cents", "line_status"],
        [[li.line_item_id, li.order_id, li.product_id, li.quantity,
          li.unit_price_in_cents, li.line_status] for li in lines],
    )
    write_csv(
        "shipments",
        ["shipment_id", "order_id", "shipped_at"],
        [[s.shipment_id, s.order_id, s.shipped_at.isoformat()] for s in shipments],
    )
    write_csv(
        "shipment_line_items",
        ["shipment_line_item_id", "shipment_id", "line_item_id", "quantity_shipped"],
        [[sl.shipment_line_item_id, sl.shipment_id, sl.line_item_id, sl.quantity_shipped]
         for sl in ship_lines],
    )

    print("generating refunds...")
    plans = pick_refund_merchants(rng, orders)
    shf, str_, pos, refund_log = gen_refunds(rng, plans, orders, lines)
    write_csv(
        "refunds_shopify",
        ["refund_id", "order_id", "line_item_id", "qty_refunded", "amount_in_cents", "refunded_at"],
        shf,
    )
    write_csv(
        "refunds_stripe",
        ["refund_id", "order_id", "tender_type", "amount_in_cents", "processed_at"],
        str_,
    )
    write_csv(
        "refunds_internal_pos",
        ["refund_id", "order_id", "amount_in_cents", "refunded_at"],
        pos,
    )

    print("loading DuckDB warehouse...")
    load_duckdb()

    con = duckdb.connect(str(DB_PATH), read_only=True)
    try:
        total_all, total_non_test = compute_reconciliation_amount(con)
    finally:
        con.close()

    print(f"reconciliation: total ${total_all:,.2f} | non-test ${total_non_test:,.2f}")

    render_ticket(total_non_test)
    _try_write_interviewer_key(mismatch_log, refund_log, total_non_test)

    print("done.")


if __name__ == "__main__":
    main()
