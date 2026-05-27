# Principal Data Engineer — Live Interview Repo

You've inherited this repo from a contractor. Finance is asking questions about the numbers it produces. Your job: investigate, fix, and improve.

## Setup (do this BEFORE the interview)

Required: Python 3.11 or 3.12 (dbt doesn't yet support 3.13+; `uv` will auto-fetch 3.12 via `.python-version` if you don't have it), `uv` (https://docs.astral.sh/uv/getting-started/installation/), `make`, `git`.

```bash
uv sync
make setup
```

`make setup` builds the DuckDB warehouse from the committed seed CSVs and runs dbt once. The seed CSVs and `DATA-123.md` are committed to the repo — you don't need to regenerate them. Re-running `make setup` rebuilds the warehouse and re-renders `DATA-123.md` from the template, so don't edit that file directly if you want notes to persist.

## Daily commands

```bash
make run      # dbt run (incremental)
make full     # dbt run --full-refresh
make test     # dbt test
make lint     # sqlfluff lint
make sql Q="select count(*) from main_orders_dw.order_fact"   # single-shot read-only query
make clean    # remove warehouse.duckdb (rebuild with `make setup`)
```

For an interactive REPL against the warehouse, install the DuckDB CLI separately (e.g. `brew install duckdb`) and open it read-only:

```bash
duckdb -readonly warehouse.duckdb
```

## Where things live

- `DATA-123.md` — your ticket. Read this first.
- `models/` — dbt models (orders, merchants).
- `setup/` — seed generator + SQL runner.
- `tests/` — singular dbt tests.
- `docs/designs/` — prior design docs from the team.
- `CONTRIBUTING.md` — team conventions.

## Bring your own AI tool

Claude Code, Cursor, Codex, etc. — bring whatever you're fast in.
