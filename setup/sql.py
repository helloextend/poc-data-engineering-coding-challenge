"""Read-only single-shot DuckDB query runner.

Usage:
    uv run setup/sql.py "select count(*) from order_fact"

Connects to ./warehouse.duckdb in read-only mode and prints results as a
plain table. No --write flag exists — the warehouse is built from dbt models.
"""

from __future__ import annotations

import sys
from pathlib import Path

import duckdb

DB_PATH = Path(__file__).resolve().parent.parent / "warehouse.duckdb"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: uv run setup/sql.py \"<query>\"", file=sys.stderr)
        return 2
    query = argv[1].strip()
    if not query:
        print("error: empty query", file=sys.stderr)
        return 2
    if not DB_PATH.exists():
        print(f"error: {DB_PATH} not found. Run `make setup` first.", file=sys.stderr)
        return 1

    con = duckdb.connect(str(DB_PATH), read_only=True)
    try:
        rel = con.sql(query)
        print(rel)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
