# Maintainers — interview repo internals

**Internal only — do not share with candidates.** This is the reference for engineers maintaining the interview rig (regenerating seeds, modifying the planted bug, calibrating across cohorts). Lives in `docs/interviewer/` so it gets scrubbed before the candidate clones.

## What's in `setup/`

| File | Purpose |
|---|---|
| `setup/generate.py` | Deterministic seed generator: writes `raw/*.csv`, loads them into `warehouse.duckdb`, renders `DATA-123.md` from the template, and (when present) regenerates [`answer-key.md`](./answer-key.md). |
| `setup/sql.py` | Read-only single-shot DuckDB query runner. Backs `make sql Q="..."`. |
| `setup/__init__.py` | Marker; keeps `setup/` importable. |

## Build modes

The Makefile exposes two flows:

- **`make setup`** — `generate.py --build-only`. Skips CSV regeneration and rebuilds `warehouse.duckdb` from the **committed** `raw/*.csv` files, then re-renders `DATA-123.md`. This is what every candidate (and you, between candidates) runs. Idempotent and cheap. **Does not regenerate [`answer-key.md`](./answer-key.md)** — the dynamic-import hook only fires in full-seed mode.
- **`make seed`** — `generate.py` with no flags. Regenerates the CSVs from scratch using `SEED = 20260517` (in `setup/generate.py`), rebuilds, and re-renders both `DATA-123.md` and [`answer-key.md`](./answer-key.md). **Only run this when you want to change the seed data.** Commit the diff so the next candidate sees the new data.

The split exists so the candidate's experience never depends on regenerating seeds — they just clone and `make setup`.

## The reconciliation number

`generate.py` computes the canonical "true" non-test revenue from the seeded line items at build time:

```python
total_non_test = sum(li.quantity * li.unit_price_in_cents for ...) / 100.0
```

That number is templated into `DATA-123.md` (replacing `{{ NON_TEST_REVENUE }}`) and into [`answer-key.md`](./answer-key.md). **Both files are committed.** When seeds regenerate, both update.

The number is **also hardcoded in two places** in [`interviewer.md`](./interviewer.md): the Problem 1 opening script, and Jamie's Q&A row. These do **not** auto-update — if you regenerate seeds, manually update both to match the new value in [`answer-key.md`](./answer-key.md).

## The interviewer-only answer-key hook

`generate.py`'s `_try_write_dev_artifacts` dynamically imports [`_answer_key.py`](./_answer_key.py) if present and calls `write_answer_key(...)` to emit [`answer-key.md`](./answer-key.md). The candidate-handoff workflow removes `docs/interviewer/` before the candidate clones, so the import silently no-ops on the candidate's machine. If you delete `docs/interviewer/`, `make seed` still works — it just skips the dev-artifact step.

The function name and comments in `generate.py` are deliberately neutral ("dev artifacts") so the file is candidate-safe as-is. Don't reintroduce `interviewer` or `answer-key` in source comments.

## Why `setup/sql.py` is the way it is

Single-shot, read-only, prints results as a plain table. It's there so candidates (and their AI tools) can spot-check the warehouse without wiring up a notebook or worrying about destructive queries. There is no `--write` flag — the warehouse is built from dbt, not by ad-hoc SQL.

## Modifying the seed data

If you change `setup/generate.py` (new patterns, more orders, different distribution):

1. Run `make seed` — regenerates `raw/*.csv`, rebuilds the DB, re-renders `DATA-123.md` and [`answer-key.md`](./answer-key.md).
2. Run `make test` — confirm the planted reconciliation warn still surfaces.
3. Update the two hardcoded numbers in [`interviewer.md`](./interviewer.md) (Problem 1 opening script, Jamie's "What's the expected reconciliation number?" row) to match the new value in [`answer-key.md`](./answer-key.md).
4. Commit `raw/*.csv`, `DATA-123.md`, [`answer-key.md`](./answer-key.md), `interviewer.md`, and your `generate.py` changes together.

## Pre-handoff scrub

Before sending the repo to a candidate, remove:

- `docs/interviewer/` (the entire folder)
- `docs/designs/` deeper layers if any are added that reference the planted bug (the existing `2024-Q3-orders-redesign.md` is intentional ambient signal — keep it)

After the scrub, run `make setup` once on a clean clone to verify the candidate experience: warehouse builds, `DATA-123.md` renders, no references to interviewer-only files surface in the candidate's tree.
