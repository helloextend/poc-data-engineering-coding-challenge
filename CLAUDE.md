# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Principal Data Engineer interview exercise: a small dbt + DuckDB warehouse inherited from a contractor. The active task is in `DATA-123.md` (Q1 revenue reconciliation against Stripe captures is off). Read it first.

`DATA-123.md` is **rendered from `DATA-123.md.tmpl` by `setup/generate.py`** — re-running `make setup` overwrites it. Don't edit it directly if you want notes to persist; put notes elsewhere.

## Commands

All commands go through the Makefile, which wraps `uv run`. Don't invoke `dbt` directly unless you have a reason — the Make targets pin the right working directory and env.

```bash
make setup      # rebuild warehouse.duckdb from raw/*.csv, then dbt full-refresh
make seed       # regenerate raw/*.csv from setup/generate.py, then full-refresh
make run        # dbt run (incremental)
make full       # dbt run --full-refresh
make test       # dbt test (singular tests in tests/ + schema tests in *.yml)
make lint       # sqlfluff lint models/
make sql Q="select count(*) from main_orders_dw.order_fact"   # read-only one-shot query
make clean      # rm warehouse.duckdb (next `make setup` rebuilds)
```

Run a single dbt model or test:

```bash
uv run dbt run --select order_fact
uv run dbt run --select +order_fact          # model + upstream
uv run dbt test --select order_fact          # all tests on a model
uv run dbt test --select test_name:order_fact_revenue_reconciliation
```

`profiles.yml` lives in the repo root (not `~/.dbt/`); dbt picks it up via project-local config. Target is `dbt_duckdb` → `./warehouse.duckdb`.

## Architecture

### Layering (enforced by convention, not tooling)

`base/` → `staging/` → (`lookup/` | `dw/`) → `reporting/`

Materializations are set in `dbt_project.yml` per layer:
- `base/`, `staging/` → views
- `lookup/` → tables
- `dw/` → **incremental** (the only persisted heavy layer)
- `reporting/` → views

Each subject area (`orders/`, `merchants/`) gets its own schema per layer (e.g. `main_orders_dw`, `main_merchants_lookup`). When writing `make sql Q=...` queries, use the fully-qualified `<schema>.<table>` name.

### Incremental pattern

`models/orders/dw/order_fact.sql` and `order_line_fact.sql` are incremental on `ordered_at`, gated by the `get_incremental_value(incr_col)` macro in `macros/get_incremental_value.sql`. The macro is a DuckDB-flavored shim of Extend's internal macro of the same name — it returns `max(incr_col)` from the existing relation, or `'1900-01-01'` on first build. The incremental `WHERE` clause uses this to filter new rows.

**Watch-out:** `order_fact.sql` currently filters incrementally on `ordered_at >= get_incremental_value('updated_at_dwh')` — note the column mismatch. If you change incremental logic, verify the watermark column matches the filter column.

### Order grain & shipment fan-out

`order_fact` is **one row per order**, but the underlying join goes through shipments → shipment_line_items → line_items, which fans out. The model deduplicates with `QUALIFY row_number() OVER (PARTITION BY order_id ORDER BY shipped_at) = 1` at the bottom. Any change touching the join keys or grain needs to keep that invariant.

`revenue` on `order_fact` is computed as `sum(quantity_shipped * unit_price)` aggregated to `(order, shipment)` then collapsed to first shipment by `shipped_at`. This is the suspected source of the DATA-123 discrepancy — orders with multiple shipments will lose revenue from non-first shipments.

### Out-of-scope by prior design

Per `docs/designs/2024-Q3-orders-redesign.md`:
- **Refunds are intentionally not modeled.** `raw/` contains `refunds_*.csv` files but they're not wired into any model. If refund logic is needed, it belongs on a separate `refund_fact`, not on `order_fact`.
- **Merchants are current-state only** (`lkp_merchants`). No Type-2 history. Tier-at-time-of-order needs a separate snapshot.

Read the design doc before proposing structural changes — its "out of scope" section reflects deliberate decisions, not gaps.

## Conventions (from CONTRIBUTING.md)

- SQL: 4-space indent, **leading commas**, lowercase identifiers, uppercase keywords. `make lint` enforces this via sqlfluff (config in `.sqlfluff`, DuckDB dialect, dbt templater).
- Every fact gets `unique` + `not_null` on its PK.
- Prefer row-level invariants over aggregate reconciliation tests — aggregates tell you something is wrong, not where.
- `severity: warn` is for noisy upstream conditions, **not** for known-broken state. The singular test `tests/order_fact_revenue_reconciliation.sql` is currently `severity='warn'` — that's a smell to investigate, not a precedent to copy.

## Seed data

`raw/*.csv` is **committed**. `setup/generate.py` is deterministic (`SEED = 20260517`) so regenerating produces identical files. Date range is 2024-11-01 → 2026-05-01 (18 months); 5k merchants, 500 products, 10k orders. Refund CSVs exist in `raw/` but are unused (see above).
