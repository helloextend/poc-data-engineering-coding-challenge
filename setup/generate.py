"""Deterministic seed generator.

Emits CSV files to raw/, builds them as DuckDB tables in warehouse.duckdb
under schema `raw`, and renders DATA-123.md from DATA-123.md.tmpl with the
canonical reconciliation number.

Run via `make setup` (which also runs dbt full-refresh after this).
"""

from __future__ import annotations

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

CUSTOMER_TYPES = ["B2B", "B2C", "MKT"]   # MKT is "marketplace"; intentionally undocumented
TIERS = ["STD", "ENT", "PLT"]            # standard / enterprise / platinum; intentionally undocumented


def random_dt(rng: random.Random, start: datetime, end: datetime) -> datetime:
    delta = end - start
    seconds = rng.randint(0, int(delta.total_seconds()))
    return start + timedelta(seconds=seconds)


def write_csv(name: str, header: list[str], rows: list[list]) -> None:
    RAW_DIR.mkdir(exist_ok=True)
    path = RAW_DIR / f"{name}.csv"
    with path.open("w", newline="") as f:
        w = csv.writer(f)
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


def main() -> None:
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

    # Orders / line_items / shipments / shipment_line_items / refunds added in later tasks.
    # DATA-123 render added in later task.

    print("done.")


if __name__ == "__main__":
    main()
