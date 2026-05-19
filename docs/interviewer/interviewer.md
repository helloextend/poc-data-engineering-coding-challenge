# Interviewer Run Sheet

**Internal only — do not share with candidates.** This is the one doc you need to run a 60-minute Principal Data Engineer interview using this repo. Everything else is referenced below.

---

## Before the call (~10 min)

1. **Build the warehouse from a clean state:**
   ```bash
   uv sync
   make clean && make setup
   ```
   `make setup` builds DuckDB from the committed seed CSVs, runs dbt, and renders `DATA-123.md`. Re-run between candidates to reset.
   
   If you've intentionally changed the seed or generator and need to regenerate the committed CSVs, run `make seed` instead — it regenerates CSVs from `setup/generate.py` and rebuilds. Commit the diff.

2. **Confirm the planted bug surfaces:**
   ```bash
   make test
   ```
   Expect a **warn** on `order_fact_revenue_reconciliation`. If it errors or passes silently, something regressed — stop and investigate before going live.

3. **Read the candidate's ticket** as it was rendered just now:
   ```bash
   cat DATA-123.md
   ```
   Note the reported reconciliation discrepancy values. Jamie reports those numbers; the candidate's job is to find the true number (**$12,989,886.01**, gross of test orders excluded).

4. **Skim, in this order:**
   - [`stakeholder-brief-jamie.md`](./stakeholder-brief-jamie.md) — Jamie's posture, sample Q&A. **Re-read sample exchanges right before the call.**
   - [`answer-key.md`](./answer-key.md) — exact numbers, planted status mismatches, refund plants.
   - [`technical-interview-design.md`](./technical-interview-design.md) — full design rationale. Section pointers below.

---

## Time budget (60 min)

| Minutes | Phase | Notes |
|---|---|---|
| 0–5 | Setup & orient | Candidate reads `README.md` and `DATA-123.md`. Don't fill silence. |
| 5–30 | Problem 1 (grain bug) | Expected ~15 min for strong candidates; 25-min ceiling is "struggling against the floor." |
| 30–55 | Problem 2 (refunds) | The asymmetric budget is deliberate — Problem 2 is the design problem and needs room to breathe. |
| 55–60 | Wrap + candidate Qs | Hard stop. |

**Sequencing rationale:** Problem 1 sets a code-shipping rhythm; Problem 2 deliberately breaks that rhythm. Whether the candidate notices the shape change *is* part of the test. See design doc § Sequencing for the full argument.

---

## Jamie (in-character stakeholder)

- **Default posture: silent.** Respond when asked, do not volunteer. Reflexively reaching for the stakeholder is itself a discriminator — wanting to ask, not asking, is a fail mode you want to observe.
- **Do not lead** to the bug, to "write a design doc", or to the ambient signals. If the candidate asks whether a design doc is expected, you can confirm yes and point to `docs/designs/2024-Q3-orders-redesign.md` as a template — but only if they ask.
- **Out-of-scope deflections** (always valid): tax, shipping refunds beyond "net of shipping", the unloaded Stripe payment export, any merchant outside the seeded set.

Sample exchanges and the full character brief: [`stakeholder-brief-jamie.md`](./stakeholder-brief-jamie.md).

---

## Problem 1 — the grain bug (gatekeeper)

**Where:** `models/orders/dw/order_fact.sql`
**Nature:** Revenue is computed by `qualify`-ing at the wrong grain. The `shipped_at` column being on an *order*-grain fact is the architectural smell that *enabled* the bug.
**True answer:** non-test revenue = **$12,989,886.01**.

**Verification commands you'll want at hand:**
```bash
make test                                                  # reconciliation warn → should pass after fix
make sql Q="select sum(revenue) from main_orders_dw.order_fact where not coalesce(is_test, false)"
```

**Three valid fix shapes (ranked):**

| Tier | What it looks like |
|---|---|
| **Principal** | Recognizes `shipped_at` doesn't belong on an order-grain fact at all. Proposes shipment metadata moves to a `shipment_fact`; `order_fact` carries only derivations (e.g., `first_shipped_at = min(shipped_at)`). |
| **Senior** | Separates CTEs: one `order_revenue` from line items (no shipments), one `order_first_ship` from shipments. Joins cleanly. Concerns separated without explicitly naming the architectural smell. |
| **Acceptable** | Keeps contractor's structure; replaces qualify with `sum(...) over (partition by order_id)`. Surgical one-line fix. |

**Flag in notes:**
- Did they run `dbt test` *before* touching code, or dive into editing?
- Did they investigate the warn-level test or shrug at it?
- Did they escalate the warn-level test to `error` after the fix? (Meta-discriminator on test-severity hygiene.)
- Did they write a **row-level parity** regression test (per-order revenue == sum of its line items), or just re-rely on the aggregate test?
- Did they identify the `shipped_at`-on-order-fact architectural smell? **(Top-tier principal signal.)**

**Boy-scout opportunities planted around the code** (bonus only — no penalty for missing): stale TODOs, commented-out source freshness, sqlfluff nits on non-`order_fact` files, undocumented columns.

Full Problem 1 design + entry ramps: design doc lines 57–219.

---

## Problem 2 — refunds across messy sources (design problem)

**The framing line you give the candidate:** *"At the end, walk us through what you'd bring to the finance analytics team for sign-off before this hits prod."* This phrasing is **deliberately neutral on format** — code, design doc, whiteboard, slack message are all valid. **Do not** say "write a design doc" — that collapses the test.

**The three allocation concerns the candidate should decompose:**
1. **Line-level allocation** — when a refund hits at order grain but lines exist, how do you allocate? (pro-rata-by-revenue? equal split? leave as order-grain?)
2. **Tender allocation** — split-tender refunds (cash + store credit). Does store credit reduce revenue? (Jamie's answer when asked: exclude store-credit refunds from headline revenue, but track separately.)
3. **Source overlap / dedup** — same logical refund could appear across `shopify_refunds`, `stripe_refunds`, and the internal POS sources. Reconciliation primitives needed.

**Planted refund nuances (cross-check candidate's work against these):**

| Order ID | Pattern | Notes |
|---|---|---|
| `O000015` | Shopify partial-line refund | 1 of 3 lines refunded |
| `O009009` | `internal_pos` order-level refund | Line statuses still `'fulfilled'` — cancel-vs-refund nuance |
| `O005064` | `shopify_stripe` split-tender | $1789.05 = $894.52 card + $894.53 store_credit |
| `O007544` | `shopify_stripe` split-tender | $1902.85 = $951.42 card + $951.43 store_credit |

Status mismatches (separate from refunds, but reachable via the same audit lens): see [`answer-key.md`](./answer-key.md) — orders `O000001`–`O000008` have planted order-status / line-status conflicts.

**What "passing" looks like:**
- Recognizes Problem 2 is a different shape than Problem 1.
- Asks Jamie at least one substantive question before writing code.
- Decomposes into the three allocation concerns above.
- Produces an artifact tailored to a finance audience with basic data-modeling vocabulary.
- If they ship code, they ship **one clean slice** (e.g., a `refund_fact` from Shopify only) with the rest as documented TODOs.

**Flag in notes:**
- **Mode-switching:** did they recognize the shape change and adjust, or keep shipping reflexively?
- Did they propose a `refund_fact` as its own model rather than dumping columns onto `order_fact`?
- Did their design name **testable invariants** — reconciliation, allocation, source-overlap?

Full Problem 2 design + "how we make the right answer available without making it obvious": design doc lines 220–303.

---

## Rubric — five dimensions

Equally weighted. **Implementation correctness is necessary but not sufficient.**

1. **AI-prompting maturity** — does the candidate orchestrate the AI's investigation (explore → explain → act → verify), or type `fix this` and watch? This is the load-bearing signal.
2. **Asks vs assumes** — questions to Jamie, questions to clarify undocumented columns, vs reflexive assumption-making. AI tools always assume — the candidate's job is to override that.
3. **Mode-switching** — Problem 2 has a different shape; do they notice?
4. **Modeling judgment** — clean diagnosis of the grain bug + architectural smell (P1); decomposition of allocation concerns + `refund_fact` proposal (P2).
5. **Scoping judgment** — punts thoughtfully with documented open questions, vs ships the wrong thing confidently. Clean slice into prod-shape > muddles through everything.

**Bonus (no penalty for missing):** boy-scout finds — stale TODOs, commented source freshness, sqlfluff nits, undocumented columns.

Full rubric + discriminators: design doc lines 399–419.

---

## Ambient signals (testing AI-prompting maturity)

These are committed artifacts that say "people who work here write designs" without saying so. A weak candidate types `fix this`; a strong candidate prompts `explore the codebase, understand conventions and prior designs, then propose an approach` — and the AI surfaces these.

- `docs/designs/2024-Q3-orders-redesign.md` — prior contractor design doc
- `CONTRIBUTING.md` — references design review
- `.github/PULL_REQUEST_TEMPLATE.md` — has a "Design link" field
- `.sqlfluff` — DuckDB-dialect lint config
- Mixed-quality column docs across `models/*.yml`

**What to watch:** did the candidate's AI surface these without being told to? That's the AI-fluency signal.

---

## Calibration (after the interview)

Jot down before context fades:
- Did the candidate message Jamie at all? When? Highest-quality question they asked?
- Which fix tier did they reach on Problem 1?
- Did they mode-switch on Problem 2 or stay in shipping mode?
- Top discriminator hit / missed?
- Did any of your responses (especially as Jamie) nudge them off-frame? Calibrate next time.

---

## Pointers index

| File | What it is | When to use |
|---|---|---|
| [`stakeholder-brief-jamie.md`](./stakeholder-brief-jamie.md) | Jamie's character, posture, sample Q&A | Re-read 5 min before the call |
| [`answer-key.md`](./answer-key.md) | Canonical numbers, planted facts | Cross-check candidate's work |
| [`technical-interview-design.md`](./technical-interview-design.md) | Full design rationale (435 lines) | Read once during onboarding; reference by section |
| [`../designs/2024-Q3-orders-redesign.md`](../designs/2024-Q3-orders-redesign.md) | Ambient signal — prior team design doc | Point candidates to *only* if asked about design process |
| [`../../README.md`](../../README.md) | Candidate-facing repo README | This is what the candidate reads first |
| [`../../DATA-123.md`](../../DATA-123.md) | Candidate-facing ticket (generated) | Regenerated each `make setup` |
