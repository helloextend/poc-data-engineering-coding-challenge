# PR Grading Rubric

**Internal only — do not share with candidates.** Use this to grade a candidate's PR for the Principal Data Engineer interview. Designed to be handed to a grading agent along with the PR diff and the interviewer's behavioral notes.

---

## How to use (instructions for the grading agent)

You are grading a Principal Data Engineer interview PR against this rubric. Inputs:

1. **The PR** — diff, commits, description, any committed design docs.
2. **Interviewer notes** — free-form observations from the live call (Section B inputs).
3. **Reference docs** for ground truth:
   - [`answer-key.md`](./answer-key.md) — canonical numbers and planted cases.
   - [`technical-interview-design.md`](./technical-interview-design.md) — design rationale.
   - `DATA-123.md` (in repo root) — the candidate's ticket.

**Process:**
1. Read the PR end-to-end before scoring.
2. Score each criterion 1–5 using the anchors below. Cite specific files/lines as evidence.
3. Compute the totals and apply the recommendation rule.
4. Produce the output in the format at the bottom of this file.
5. Be honest about uncertainty — if a criterion isn't gradable from the PR, say so.

**Scoring anchors (apply to every criterion):**

| Score | Meaning |
|---|---|
| 1 | Missing or wrong. The PR shows no engagement with this dimension, or actively works against it. |
| 2 | Partial / surface-level. Acknowledged but not addressed substantively. |
| 3 | Acceptable. Meets the senior-engineer bar. |
| 4 | Strong. Above bar — clear thought, solid execution. |
| 5 | Exemplary. Principal-level signal — names the deeper issue, makes a non-obvious right call, or demonstrates rare judgment. |

---

## Section A — PR-observable criteria

These are graded from the PR diff alone. The grading agent should be able to score these without interviewer input.

### A1. Problem 1 — Bug diagnosis & fix correctness *(gatekeeper)*

Did the candidate fix the grain bug in `models/orders/dw/order_fact.sql`?

| Score | Anchor |
|---|---|
| 1 | Bug not fixed; reconciliation still off; or fix breaks other models. |
| 2 | Fix produces correct totals but mechanism is unclear or fragile (e.g., changes the test instead of the model). |
| 3 | **Acceptable tier**: replaces `qualify` with `sum(...) over (partition by order_id)` or equivalent — surgical one-line fix. Correct totals, comment updated. |
| 4 | **Senior tier**: separates concerns into distinct CTEs — one for `order_revenue` from line items, one for `order_first_ship` from shipments. Joins cleanly. |
| 5 | **Principal tier**: recognizes `shipped_at` doesn't belong on an order-grain fact at all. Proposes (or implements) moving shipment metadata to a `shipment_fact`; `order_fact` carries only derivations like `first_shipped_at = min(shipped_at)`. |

**Verify:** `sum(revenue) where not coalesce(is_test, false)` should equal the value in [`answer-key.md`](./answer-key.md) under "True reconciled non-test revenue".

**Gatekeeper rule:** A1 < 3 → no hire regardless of other scores.

### A2. Problem 1 — Test hygiene

What did the candidate do with the warn-level reconciliation test (`tests/order_fact_revenue_reconciliation.sql`) and what regression coverage did they add?

| Score | Anchor |
|---|---|
| 1 | Removed, weakened, or ignored the warn test. No new tests. |
| 2 | Left the warn at `warn` severity. No new tests. |
| 3 | Escalated the existing test from `warn` → `error` post-fix. No new tests. |
| 4 | Escalated to `error` AND added at least one new test (e.g., a row-level parity check) covering the regression. |
| 5 | Wrote a row-level parity invariant (per-order revenue == sum of its line items) as a generic/reusable test, escalated severity, and the test would have caught the original bug. |

### A3. Problem 2 — Refund model structure

Did the candidate propose or build a `refund_fact` model rather than dumping refund columns onto `order_fact`?

| Score | Anchor |
|---|---|
| 1 | Refund logic crammed into `order_fact` with no separate model; conflates allocation concerns. |
| 2 | Single refund model exists but conflates line / tender / source concerns into one table. |
| 3 | Separate `refund_fact` (or equivalent) at a defensible grain. Joins to `order_fact`/`order_line_fact` cleanly. |
| 4 | `refund_fact` at a clearly justified grain, with an `order_line_fact.refunded_amount` column populated via documented allocation logic. |
| 5 | Layered model: a raw `refund_fact` preserving source grain, plus derived columns on order/line facts via documented allocation. Treats raw refunds and allocated refunds as different artifacts. |

### A4. Problem 2 — Allocation decomposition

Does the PR (code or design doc) decompose the three orthogonal allocation concerns?

The three concerns:
1. **Line allocation** — when refund hits at order grain but lines exist (Stripe, internal POS), how to populate `order_line_fact.refunded`.
2. **Tender allocation** — split-tender refunds; whether store credit reduces revenue.
3. **Source reconciliation** — same logical refund across `refunds_shopify` / `refunds_stripe` / `refunds_internal_pos`, no shared ID.

| Score | Anchor |
|---|---|
| 1 | None of the three named or addressed. |
| 2 | One of three addressed (typically tender, since Jamie volunteers it). |
| 3 | Two of three named with a stated approach. |
| 4 | All three named, each with a stated approach and tradeoffs. |
| 5 | All three named as *orthogonal* concerns (the principal-level insight), with explicit testable invariants for each (e.g., "sum of allocated line refunds == order refund total"). |

### A5. Problem 2 — Planted refund cases

Does the candidate's work correctly handle (or explicitly call out) the planted refund cases listed in [`answer-key.md`](./answer-key.md)?

The expected handling for each pattern:

| Pattern | Expected handling |
|---|---|
| Shopify partial-line refund | Line-level refund flows through to the refunded line only |
| Internal POS order-level refund (line statuses still `fulfilled`) | Cancel-vs-refund nuance noted; refund applied without changing line status |
| `shopify_stripe` split-tender (card + store_credit) | Store credit excluded from headline revenue; cash portion reduces revenue. **Multiple instances planted** — see [`answer-key.md`](./answer-key.md). |

**Use [`answer-key.md`](./answer-key.md) for the canonical order IDs, amounts, and instance counts** — they regenerate when seeds change.

| Score | Anchor |
|---|---|
| 1 | None handled or named. |
| 2 | One pattern handled. |
| 3 | Two patterns handled, or all named with deferred handling notes. |
| 4 | Three patterns handled correctly; any remaining ones explicitly deferred with rationale. |
| 5 | All patterns handled correctly OR all named as testable cases in a design with a clean slice shipped covering at least two. |

### A6. Scoping & artifact quality

Did the candidate ship a clean slice or muddle through everything?

| Score | Anchor |
|---|---|
| 1 | PR is incomplete in unprincipled ways — half-built models, broken tests, no clear scope. |
| 2 | Tries to do everything; some pieces work, others are half-done with no documentation of what's missing. |
| 3 | Clear scope. What's done is done; what's not is acknowledged. |
| 4 | Clear scope with a deliberate "clean slice" (e.g., Shopify-only `refund_fact`) and documented TODOs for the rest. |
| 5 | Clean slice + an artifact (design doc, PR description, markdown in repo) tailored to a finance audience surfacing assumptions, open questions, and which questions block prod vs. can be deferred. |

### A7. Boy scout finds *(bonus, +0 to +3 to total)*

Realism props planted around the repo. Bonus only — no penalty for missing.

Cheap-tier finds available:
- Stale TODO on an unrelated model
- Commented-out source freshness config
- sqlfluff nits on non-`order_fact` files
- Undocumented columns in `models/*.yml`
- Order/line status mismatches surfaced via the same audit lens (planted on `O000001`–`O000008`; canonical list in [`answer-key.md`](./answer-key.md))

| Bonus | Anchor |
|---|---|
| +0 | None addressed. |
| +1 | One or two unrelated finds fixed in the PR. |
| +2 | Three+ finds, or one find paired with documentation explaining the systemic issue. |
| +3 | Identifies the *category* (e.g., "we have stale config across the orders project") and proposes a sweep, not just a one-off fix. |

---

## Section B — Interviewer-observed criteria

These cannot be graded from the PR. The interviewer fills in observations during/after the call; the grading agent scores Section B from those notes.

Interviewer notes should follow the template at [`section-b-notes-template.md`](./section-b-notes-template.md).

If interviewer notes are absent, mark each B criterion as "not graded — no observations provided" rather than guessing.

### B1. AI-prompting maturity

Did the candidate orchestrate the AI's investigation, or type `fix this` and watch?

| Score | Anchor |
|---|---|
| 1 | Typed terse commands (`fix this`, `find the bug`); accepted first AI output without verification. |
| 2 | Multi-step prompts but no verification step; accepted AI claims without checking source. |
| 3 | Explore → act → verify cycle visible. Pushed back on at least one wrong AI claim. |
| 4 | Prompted AI to read conventions / prior designs before acting. Verified factual claims against source. Iterated on prompts when results were off. |
| 5 | Treated AI as a junior engineer to be supervised: explore the codebase, explain before changing, propose options before implementing. Caught and corrected at least one AI hallucination. |

### B2. Asks vs assumes

Did the candidate ask Jamie / clarify undocumented columns, or reflexively assume?

| Score | Anchor |
|---|---|
| 1 | Zero questions asked. Made silent assumptions on every ambiguity. |
| 2 | One low-quality question (e.g., "what's the goal?"). |
| 3 | Asked at least one substantive question before writing P2 code. |
| 4 | Asked multiple substantive questions; surfaced assumptions explicitly even when not asking. |
| 5 | Asked questions that *re-shaped* the approach (e.g., asked about store-credit treatment before designing tender allocation). Surfaced assumptions in the PR/design doc with rationale. |

### B3. Mode-switching

Did the candidate recognize Problem 2 has a different shape than Problem 1?

| Score | Anchor |
|---|---|
| 1 | Stayed in code-shipping mode through P2. Built the wrong thing confidently. |
| 2 | Started in shipping mode; pivoted late after hitting a wall. |
| 3 | Recognized the shape change after some friction; produced a partial design alongside code. |
| 4 | Recognized the shape change early; led with decomposition before any SQL. |
| 5 | Articulated the shape change explicitly ("this is a design problem, not a bug fix"); produced a deliberately scoped artifact (design + clean slice) tailored to the finance audience. |

---

## Recommendation

### Compute totals

- **Section A total** (out of 30): A1 + A2 + A3 + A4 + A5 + A6
- **Section B total** (out of 15): B1 + B2 + B3
- **Combined** (out of 45): Section A + Section B
- **With bonus** (out of 48): Combined + A7

### Recommendation rule

Apply in order — first match wins:

| Recommendation | Rule |
|---|---|
| **No hire** | A1 < 3 (gatekeeper failed) — regardless of other scores. |
| **No hire** | Combined < 25. |
| **Lean no hire** | Combined 25–29, OR any criterion at 1. |
| **Lean hire** | Combined 30–34, no criterion at 1, A1 ≥ 3. |
| **Hire** | Combined 35–39. |
| **Strong hire (Principal)** | Combined ≥ 40 AND at least two criteria at 5 across A1, A3, A4, A6 (the principal-signal criteria). |

The bonus (A7) does not change the recommendation tier on its own but is reported alongside.

---

## Output format (what the grading agent should produce)

```markdown
# PR Grading — <candidate name / PR link>

## Summary
- **Recommendation:** <No hire | Lean no hire | Lean hire | Hire | Strong hire>
- **Combined:** XX/45 (+X bonus)
- **Section A:** XX/30 — **Section B:** XX/15

## Section A — PR-observable
| Criterion | Score | Evidence |
|---|---|---|
| A1. P1 bug fix | X/5 | `models/orders/dw/order_fact.sql:LL` — <brief> |
| A2. Test hygiene | X/5 | `tests/...:LL` — <brief> |
| A3. Refund model structure | X/5 | <files/lines> — <brief> |
| A4. Allocation decomposition | X/5 | <files/lines> — <brief> |
| A5. Planted refund cases | X/5 | <which handled> |
| A6. Scoping & artifact quality | X/5 | <brief> |
| A7. Boy scout (bonus) | +X/3 | <finds> |

## Section B — Interviewer-observed
| Criterion | Score | Evidence from notes |
|---|---|---|
| B1. AI-prompting maturity | X/5 | <quote/paraphrase> |
| B2. Asks vs assumes | X/5 | <quote/paraphrase> |
| B3. Mode-switching | X/5 | <quote/paraphrase> |

## Strengths
- <bullet>

## Concerns
- <bullet>

## Open questions for the interviewer
- <anything the PR + notes didn't resolve>
```
