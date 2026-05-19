# Contributing

## Style

- SQL: 4-space indent, leading commas, lowercase identifiers, uppercase keywords. Run `make lint`.
- Models follow the layering convention from our parent dbt repo: `base/` → `staging/` → (`lookup/` | `dw/`) → `reporting/`.

## Tests

- Every fact gets `unique` + `not_null` on its primary key.
- Aggregate reconciliation tests are useful but coarse — they tell you something is wrong, not where. Prefer row-level invariants where practical.
- A failing test should fail loudly. `severity: warn` is for noisy upstream conditions, not for "we know this is broken."

## Design review

Non-trivial work goes through design review before code. Past designs live
in `docs/designs/`. Use them as templates. If you're not sure whether your
work needs a design doc, ask before you start coding.
