# Refunds & Net Revenue — Finance Readout

Paste-ready outline for Google Slides. One slide per `---`-separated block.
For each slide: title goes in the slide title field, body goes in the body,
and the **Speaker notes:** block goes in the notes pane.

Audience: Jamie + finance stakeholders. Lean outcome-focused, not jargon-heavy.

---

## Slide 1 — Title

**Refunds & Net Revenue**
A design readout for Finance

Presented by: Data Engineering
Date: [fill in]

**Speaker notes:**
This readout covers two things — what we fixed in the Q1 revenue numbers, and
how we'll bring refunds into the warehouse so finance can pull net revenue and
reconcile to Stripe settlement. ~10 slides. We need 2 decisions from finance by
the end (3 are already decided as of this draft).

---

## Slide 2 — TL;DR

- **Q1 revenue is fixed.** `order_fact.revenue` now ties to Stripe captures exactly: **$12,989,886.01**.
- **Refunds aren't in the warehouse yet.** Net revenue and Stripe-settlement reconciliation are blocked until we land that work.
- **2 decisions still open** for finance (5 total — 3 already locked in).

**Speaker notes:**
Three things on this slide. The first is closed — DATA-123 is fixed and a PR
is open for review. The second is the work we're scoping today. The third is
the ask: we need finance to weigh in on a few design questions before we can
build cleanly. The five questions are on slide 9.

---

## Slide 3 — Q1 revenue gap: found and fixed (DATA-123)

**Before:**
- `order_fact.revenue` (non-test) = **$10,522,258.04**
- Stripe captures (target) = **$12,989,886.01**
- Gap: **$2,467,627.97**

**Root cause:** revenue was computed from shipments, not orders. Two interacting bugs:
- ~$1.55M lost — orders without shipments yet were silently dropped
- ~$0.92M lost — orders with multiple shipments only counted the first one

**After fix:** $12,989,886.01 — matches Stripe to the penny.
PR open (PR #5). Reconciliation test now runs at `error` severity (build fails loudly if this ever drifts again).

**Speaker notes:**
The Q1 number was off by ~$2.5M. Root cause: the model was building revenue
from the wrong table — shipments instead of line items. The design doc actually
said revenue should come from line items; the contractor's code didn't follow
the spec. Fixed by rewriting the model to match the documented definition.

We also bumped the reconciliation test from "warning" to "error" — so if this
class of bug ever returns, dbt runs fail loudly instead of just logging a warning.

---

## Slide 4 — What's next: net revenue + Stripe settlement recon

Finance needs:
- `refund_amount` and `net_revenue` columns on `order_fact`
- Per-line refund amounts on `order_line_fact`
- A reconciliation column that matches Stripe settlement reports

What we have to build with: **three refund sources in raw** — `refunds_stripe`, `refunds_shopify`, `refunds_internal_pos`.

Each source records refunds from a different perspective. That's where the design problem lives.

**Speaker notes:**
This is the work we're scoping. Two goals: produce net revenue numbers finance
can use day-to-day, and let Jamie tie a column directly to the Stripe settlement
report. We have three refund sources to merge. Calling that out upfront because
it's the meat of the problem — it's not "load one table and add a column," it's
"reconcile three sources of the same events."

---

## Slide 5 — What the refund data looks like

| Source | Has line_item_id? | Tender split? | Refund grain in source |
|---|---|---|---|
| Shopify | **Yes** | No | One row per (refund, line) with qty refunded |
| Stripe | No | **Yes** (card, store_credit) | One row per (refund, tender_type) |
| Internal POS | No | No | One row per refund |

**Same refund event can appear in multiple sources for the same order.**
Example: a card refund processed through Shopify shows in both Shopify (line-level) AND Stripe (payment-level).

**Speaker notes:**
Each source records refunds from its own perspective. Shopify is the
order-management view — it knows which product line and how many units were
returned. Stripe is the payment-processor view — it knows how the money flowed
back, split by tender type (card vs. store credit). Internal POS is a catch-all
for non-Shopify, non-Stripe events.

The kicker is that the same refund often appears in two sources. That's the
central design problem we have to solve.

---

## Slide 6 — Watch-outs: 4 traps in the raw data

We inspected all 12 refund rows currently in raw. **Every grain trap that'll bite us at production scale already shows up in this small sample.**

| # | Trap | Concrete example from raw data |
|---|---|---|
| 1 | **Cross-source double-count** | O005064: refunded once, recorded in BOTH Shopify ($1,789.05) AND Stripe ($894.52 card + $894.53 store_credit). Naive union = $3,578.10 (2x the real refund). |
| 2 | **Within-Stripe tender split** | One refund event becomes multiple Stripe rows when split between card and store credit (same `processed_at`). Even within Stripe, `refund_id` ≠ refund event. |
| 3 | **Sub-line partial-qty refunds** | O000015: a line had qty 3, customer returned qty 1. Refund grain is *finer* than line grain. Fine for dollar sums; matters if anyone ever wants "qty refunded per line." |
| 4 | **Order-grain refunds, no line detail** | O000286 (Stripe only) and O009009 (POS only): full refund recorded, multi-line orders, source doesn't say which line. We have to allocate. |

**Speaker notes:**
This is the most important slide. The data we have today is tiny — 12 raw rows
— but it already contains every grain trap we'll hit at scale. Walking through
each:

[Trap 1] When a card refund flows through Shopify, both Shopify and Stripe
record it independently. If we naively union the sources, we double-count.

[Trap 2] Stripe splits a single refund into multiple rows when it's part-card
part-store-credit. Same event, two rows.

[Trap 3] Customer returns 1 of 3 units on a line. Refund amount is fine; if
finance ever wants "quantity refunded per line" detail, that lives at a finer
grain (a separate model).

[Trap 4] Stripe-only and POS-only refunds give us no line attribution at all.
For per-line refund amounts, we have to allocate.

These four traps are the design pressure. The model below is shaped around
handling all of them correctly.

---

## Slide 7 — Proposed model

**Two new tables**, separate from `order_fact` (per the prior 2024-Q3 design doc — refund logic shouldn't live on the order grain, or status/revenue reasoning gets tangled again).

- **`refund_fact`** — one row per *real* refund event (de-duped across sources).
  - Columns: `order_id`, `refunded_at`, `refund_amount`, `source_system`, `has_line_attribution`, **`stripe_settled_amount`** (this is the Stripe-recon column)

- **`refund_line_fact`** — one row per (refund event, line item).
  - Direct `line_item_id` from Shopify when present.
  - Pro-rata allocation by line revenue when source doesn't carry line detail. ← *Decision #4, confirmed*

**Then denormalized columns added to existing facts:**
- `order_fact.cash_refund_amount` — card refunds + POS refunds (what reduces revenue)
- `order_fact.store_credit_issued` — separate, tracked as deferred liability ← *Decision #3*
- `order_fact.net_revenue` = `revenue − cash_refund_amount` (store credit excluded until redeemed)
- `order_line_fact.cash_refund_amount`, `order_line_fact.net_line_revenue`

**Invariant:** `cash_refund_amount + store_credit_issued = total_refund_amount` (per order).

**Speaker notes:**
Two new tables. The reason we don't just bolt all this onto order_fact is that
the prior design doc was specific: keep refund logic off the order grain. The
contractor warned us that mixing refund logic with status/revenue logic on a
single table creates the kind of bug DATA-123 was — and we'd be re-creating
that problem.

So: refund *logic* (dedup, attribution, allocation, tender breakdown) lives in
the new tables. The order tables only get the *numbers* added as denormalized
columns. That way finance still gets `net_revenue` directly on `order_fact`
without paying the design cost.

Worth highlighting the split: `cash_refund_amount` and `store_credit_issued`
are tracked separately on order_fact because they mean different things to
finance. Cash refunds reduce revenue immediately. Store credit is a deferred
liability — revenue stays whole until the credit is redeemed, at which point
it offsets a future order. We don't have store-credit-redemption data today,
so we just isolate the liability column for now and flag the offset modeling
as a follow-up.

---

## Slide 8 — What finance can do with this

| Question finance wants to answer | Query |
|---|---|
| Q1 net revenue? | `sum(net_revenue)` from `order_fact` where `ordered_at` in Q1 |
| Net revenue by week? | Same, group by week of `ordered_at` ← *Decision #5: refunds attribute back to order date* |
| Tie out to Stripe settlement for May? | `sum(stripe_settled_amount)` from `refund_fact` where `refunded_at` in May |
| Outstanding store-credit liability? | `sum(store_credit_issued)` from `order_fact` |
| Why did this order's net revenue drop? | `refund_fact` rows for that order |
| Which line on this order got refunded? | `refund_line_fact` rows for that order |

**Net revenue definition** (per Decision #3): `revenue − cash_refund_amount`. Store credit does **not** reduce net revenue at issuance — it stays as a deferred liability until redeemed.

**Built-in guardrail:** dbt test asserts `sum(order_line_fact.cash_refund_amount per order) = order_fact.cash_refund_amount`. Stops the next DATA-123-style drift before it ships.

**Speaker notes:**
This is the day-to-day use case slide. If Jamie can answer all five of these
without a custom one-off query, the model is doing its job.

Two things worth flagging: (1) net revenue by date uses the *order* date, not
the refund date — that's Decision #5. It means Q1's net revenue number is
*stable* once Q1 closes; a Q2 refund of a Q1 order shows up in Q1. That's the
accrual-accounting view, which matches how finance usually thinks. (2) The
reconciliation column for Stripe settlement is on `refund_fact`, not
`order_fact` — keeps the order table narrow.

The dbt guardrail at the bottom is the lesson from DATA-123: build the
reconciliation test up front, run at error severity, so we catch drift the
moment it happens.

---

## Slide 9 — Decisions from finance

Three locked in. Two open.

| # | Question | Status | Direction |
|---|---|---|---|
| 1 | Same refund in Shopify AND Stripe — which is canonical? | **Open** | Default: Shopify (has line-level detail) |
| 2 | Stripe settlement scope — card only, or all tenders? | **Open** | Default: card only (matches what Stripe actually settles) |
| 3 | Store credit treatment — refund or deferred liability? | **Decided** | **Deferred liability.** Doesn't reduce net revenue until redeemed ✓ |
| 4 | Allocate per-line refunds when source has no `line_item_id` — how? | **Decided** | Pro-rata by line revenue ✓ |
| 5 | "Q1 net revenue" — refunds bucket by order date or refund date? | **Decided** | **Order date** ✓ |

Slack draft ready for Jamie on #1 and #2.

**Speaker notes:**
Decision summary. Three locked in:
- #3: store credit is a deferred liability, not a revenue reversal. Net revenue
  only moves when actual cash moves (card + POS refunds). Store credit gets its
  own column, tracked as a liability until redeemed.
- #4: pro-rata allocation for per-line refunds when the source doesn't carry
  line detail. Preserves the order = sum-of-lines invariant.
- #5: net revenue by date attributes refunds back to the original order's
  date. Means Q1 numbers stay stable as later refunds come in — the accrual
  view finance typically wants.

Two still open — dedup precedence and Stripe settlement scope. Slack draft is
ready for Jamie. Defaults in the table are what we'd build if no input, but
we'd rather get her read explicitly.

---

## Slide 10 — Timeline & next steps

**Done**
- DATA-123 (Q1 revenue fix) — PR #5 open for review

**Pending finance**
- Decisions #1 and #2 (Slack draft ready to send)

**After decisions land**
- Short design doc → review → build:
  - `base_refunds_*` (one per source)
  - `stg_refunds` (unioned, canonical schema)
  - `refund_fact` (de-duped refund events)
  - `refund_line_fact` (per-line allocations)
  - `refund_amount`, `net_revenue` columns on `order_fact` and `order_line_fact`
  - Reconciliation tests at `error` severity
- Estimate: ~2 days build + 1 day review

**Follow-ups (not in this scope)**
- **Store credit redemption modeling.** When a customer redeems store credit on a future order, that's when net revenue should reduce. Needs a store-credit-redemption data feed we don't have yet — `store_credit_issued` is the liability holder until then.
- Stripe settlement-report ingestion (automate the recon vs manual)
- Per-line *qty* refund detail (only if finance ever needs it)

**Speaker notes:**
DATA-123 is closed pending merge. Refunds work is blocked on Jamie's input
but can kick off the day after we hear back. Build is ~2 days, review another
day, so end-to-end ~3 working days from green-light.

Three follow-ups are explicitly out of scope. Calling them out so they don't
surprise anyone later — store credit redemption matters most: today
`store_credit_issued` just accumulates as a liability column. Once we get a
redemption feed, we can close that loop and reduce net revenue at redemption
time. Until then, finance can still see total outstanding store-credit
liability per merchant by summing the column.

---

## Appendix — Source data for reference

12 raw refund rows total across the three sources. Sample below for completeness; happy to walk through any specific row.

```
refunds_stripe (5 rows):
  STR000002  O000286  card           $1,925.22  2025-03-09
  STR000005  O005064  card             $894.52  2026-04-18
  STR000006  O005064  store_credit     $894.53  2026-04-18  ← same event as STR000005
  STR000008  O007544  card             $951.42  2025-11-21
  STR000009  O007544  store_credit     $951.43  2025-11-21  ← same event as STR000008

refunds_shopify (3 rows):
  SHF000001  O000015  L0000029  qty=1  $367.70   2026-02-01
  SHF000004  O005064  L0009590  qty=5  $1,789.05 2026-04-18  ← same event as STR000005+006
  SHF000007  O007544  L0014230  qty=5  $1,902.85 2025-11-21  ← same event as STR000008+009

refunds_internal_pos (1 row):
  POS000003  O009009  $1,212.11  2026-05-11
```

**Speaker notes:**
Backup slide if anyone wants to walk the actual rows. The arrows mark the
cross-source duplicates that drive Decision #1.
