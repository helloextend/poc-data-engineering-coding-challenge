# Refunds modeling — net revenue for `order_fact` / `order_line_fact`

**Author:** Data Engineering
**Status:** Draft — for review with Finance Analytics
**Date:** 2026-05-20
**Related:** [`2024-Q3-orders-redesign.md`](2024-Q3-orders-redesign.md) (out-of-scope item: refunds), DATA-145 (refund sources, not yet scoped), DATA-123 (Q1 revenue reconciliation — gross-revenue bug, separate issue)

---

## 1. What Finance asked for

> Surface refund totals on `order_fact` and per-line refund amounts on `order_line_fact` so we can report **net revenue** (gross − refunds).

This document captures the modeling decisions we recommend. We want sign-off on the decisions in §3 and §5 before we touch any SQL.

### Two items to highlight up front

These are covered in detail below, but they're the two decisions most likely to matter to Finance, so we want them on the table before the walkthrough:

1. **Shopify/Stripe dedup is a heuristic (§3.3).** The same logical refund appears in both Shopify and Stripe in our sample data — Shopify carries the line + amount, Stripe carries the tender split. Summing them double-counts. We propose matching on `(order_id, refunded_at_minute)` and treating Shopify as the source of truth for occurrence/amount. **If Finance has a real `gateway_refund_id` cross-walk available in production, we should use that instead** — it's exact, the heuristic is not. See open question E.

2. **Late-arriving refunds are the operational gotcha (§4).** `order_fact` today filters incremental loads on `ordered_at` only. A refund processed today against an order from three months ago would not refresh that order's row — its `net_revenue` would silently stay wrong. The fix is an `OR` clause on "orders with new refund activity since last run." **This directly affects the question "when do my numbers reflect today's refunds?"** — incremental runs will pick up new refunds against historical orders within one cycle, not never.

## 2. What's in raw today

Three refund feeds are landed in `raw/` but **not wired into any model**:

| Source                    | Grain          | Key fields                                                        | Notes                                                                |
|---------------------------|----------------|-------------------------------------------------------------------|----------------------------------------------------------------------|
| `refunds_stripe.csv`      | order × tender | `refund_id`, `order_id`, `tender_type`, `amount_in_cents`, `processed_at` | Multiple rows per refund event when a refund is split across tenders (e.g., card + store_credit). Per-line detail not available. |
| `refunds_shopify.csv`     | order × line   | `refund_id`, `order_id`, `line_item_id`, `qty_refunded`, `amount_in_cents`, `refunded_at` | Has line-level detail and quantity refunded. No tender breakdown.    |
| `refunds_internal_pos.csv`| order          | `refund_id`, `order_id`, `amount_in_cents`, `refunded_at`         | In-store register; standalone, no Shopify/Stripe pairing.            |

**Observation (important):** the same refund event sometimes appears in **both** Stripe and Shopify. Example in current sample data, order `O005064` at `2026-04-18T23:12:12`:

- Shopify: 1 row, `178,905¢` against `L0009590`, `qty_refunded = 5`.
- Stripe: 2 rows totaling `178,905¢` (`89,452¢` card + `89,453¢` store_credit).

These describe the same money moving — Shopify is the system of record for **what was refunded** (line, quantity), Stripe is the system of record for **how it was paid back** (tender). Summing across sources would double-count. Our model must pick a precedence rule (see §3).

POS appears to be standalone (separate register, no e-commerce pairing). Treat it as additive.

## 3. Modeling decisions

### 3.1 Build a separate `refund_fact` (one row per refund event)

We keep the Q3-2024 design principle intact: **don't tangle refund logic with order status/revenue logic on `order_fact`**. Refund details live on their own fact; `order_fact` and `order_line_fact` carry **aggregates** of that fact.

```
base/  refunds_stripe, refunds_shopify, refunds_internal_pos
staging/  stg_refunds      ← unified, deduped, line-aware where possible
dw/       refund_fact      ← one row per logical refund × line
          order_fact       ← gains refund_total, refund_count, last_refunded_at, net_revenue
          order_line_fact  ← gains refund_amount, qty_refunded
reporting/  rpt_net_revenue (or similar, per Finance preference)
```

### 3.2 Grain of `refund_fact`: **order × line × refund_event**

One row per (order_id, line_item_id, refund_id). For order-grain sources (POS, Stripe-only), `line_item_id` is `NULL` and the amount is carried on a single row per refund_id. The line-grain `refund_amount` on `order_line_fact` then uses allocation (§3.4) to fill in unallocated amounts.

This is more granular than strictly necessary for the finance asks, but it's the grain that lets us answer:

- "What was refunded?" (line + quantity) — from Shopify directly.
- "How was it paid back?" (tender) — joinable to Stripe rows by (order_id, refunded_at).
- "Was this in-store or online?" — derivable from `source`.

### 3.3 Source precedence to dedupe Shopify ↔ Stripe overlap

We treat **Shopify as the system of record for refund occurrence + line + amount**, and **Stripe as the system of record for tender mix only**. Concretely, in `stg_refunds`:

1. Start with all Shopify rows (line-grain).
2. Add Internal POS rows (line_item_id NULL).
3. Add Stripe rows **only if `(order_id, refunded_at_minute)` does not appear in Shopify** — these are Stripe-direct refunds (e.g., issued from the Stripe dashboard, no Shopify counterpart).
4. Tender breakdown becomes a sidecar: `stg_refund_tenders` (order_id, refund_event_key, tender_type, amount) for downstream reporting that needs it. Not joined into `refund_fact`.

This is a heuristic. We'd like Finance to confirm whether they have a stronger key from upstream (e.g., a `gateway_refund_id` cross-walk) — see §8.

### 3.4 Allocation of order-grain refunds to lines

For refunds where `line_item_id IS NULL` (POS, Stripe-direct), we cannot know which line was refunded. To populate `order_line_fact.refund_amount` we allocate **pro-rata by line revenue**:

```
line_refund_share = line_revenue / order_revenue
allocated_refund   = order_refund_amount * line_refund_share
```

We carry an explicit flag `refund_allocation_method ∈ {'direct', 'pro_rata'}` on `order_line_fact` so analysts can see when a line's refund came from a real Shopify attribution vs. a derived split. The sum across lines still ties to `order_fact.refund_total` to the penny (we round-pennies the largest line to absorb rounding drift — same trick as Stripe's `presentment_money` allocation).

**Alternative we considered and rejected:** leave un-allocated. That's cleaner but breaks Finance's "per-line net revenue" report — every POS order would have NULL refund attribution. Pro-rata with a method flag preserves both: rollups stay accurate and analysts can filter to `direct`-only lines when investigating returns by SKU.

### 3.5 What columns go on `order_fact`

| Column                  | Definition                                                              |
|-------------------------|-------------------------------------------------------------------------|
| `refund_total`          | `sum(refund_fact.amount)` per order, in dollars (consistent with `revenue`) |
| `refund_count`          | `count(distinct refund_id)` per order                                   |
| `last_refunded_at`      | `max(refunded_at)` per order                                            |
| `net_revenue`           | `revenue - coalesce(refund_total, 0)`                                   |
| `is_fully_refunded`     | `refund_total >= revenue` (handles goodwill/over-refund as TRUE)        |

Nullability: `refund_total` is `coalesce(..., 0)` — every order has a value, even if zero. This makes downstream `net_revenue` filters and aggregations straightforward (no `IS NULL` traps).

### 3.6 What columns go on `order_line_fact`

| Column                     | Definition                                                  |
|----------------------------|-------------------------------------------------------------|
| `qty_refunded`             | From Shopify when available; else `NULL` (we don't fabricate qty for allocated rows) |
| `refund_amount`            | Direct from Shopify OR pro-rata allocated (see §3.4)        |
| `refund_allocation_method` | `'direct' \| 'pro_rata' \| 'none'`                          |
| `net_line_revenue`         | `line_revenue - coalesce(refund_amount, 0)`                 |

## 4. Incremental + late-arriving refunds (the operational gotcha)

This is the single most important production decision. Worth slowing down on.

The current incremental pattern on `order_fact` filters on `ordered_at >= get_incremental_value('ordered_at')`. **Refunds arrive days, weeks, or months after the order.** A refund processed today against an order from three months ago will not be picked up by an `ordered_at`-filtered incremental load — `order_fact` row for that order would never refresh.

We resolve this in two pieces:

1. **`refund_fact` is incremental on `refunded_at`** (the refund event's own date). Standard pattern.
2. **`order_fact` and `order_line_fact` switch from a single-watermark filter to a union of "new orders" and "orders with new refund activity":**

```sql
WHERE o.ordered_at >= {{ get_incremental_value('ordered_at') }}
   OR o.order_id IN (
       SELECT order_id FROM {{ ref('refund_fact') }}
       WHERE refunded_at >= {{ get_incremental_value('refunded_at_dwh') }}
   )
```

This re-processes any order whose refund picture changed since the last run, without re-processing the entire history. We'll also need an `updated_at_dwh` column on `order_fact` that bumps whenever refund aggregates change — handy for downstream consumers and required for the watermark column we read above.

**Backfill on first deploy:** one full-refresh (`make full`) to pick up historical refunds against all historical orders. Incremental thereafter.

## 5. Scope decisions for sign-off

These are choices we'd like Finance to explicitly confirm or correct:

| # | Question                                                                                | Our recommendation                                                                                                                                                  |
|---|-----------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A | Does "net revenue" = `revenue − refund_total`?                                          | **Yes.** Cancellations are already handled by `order_status` (pre-payment voids never hit gross revenue); refunds are the only post-payment reversal we model here. |
| B | If `refund_total > revenue` (goodwill, overpayment), should `net_revenue` go negative?  | **Yes, surface the truth.** Don't clamp at zero. Add a data-quality test at `severity='warn'` so Finance is notified, not silenced. |
| C | Should refunds from test orders (`is_test = true`) be excluded?                         | **Yes, same as gross revenue.** Reporting layer applies `is_test = false` consistently.                                                                              |
| D | Is per-tender breakdown (card vs. store_credit) needed on `order_fact`?                 | **No.** Sidecar `stg_refund_tenders` covers anyone who needs it; keeping `order_fact` narrow.                                                                       |
| E | Shopify-vs-Stripe dedup rule (§3.3) — does Finance have a better key than `(order_id, minute)`? | **Need input.** If a `gateway_refund_id` mapping exists in source, use it; otherwise we go with the heuristic and add a monitoring test.                            |
| F | How should refunds for **shipped** vs **not-yet-shipped** lines be treated?             | **Same treatment.** Both reduce net revenue. (Worth noting because some businesses differentiate; we don't think we should.)                                        |
| G | Tax / shipping refunds — included in `amount_in_cents`?                                 | **Assumed yes (gross-of-tax).** Mirrors how `revenue` is currently computed (`quantity * unit_price`, no tax breakout). If Finance reports net-of-tax separately, that's a follow-up. |

## 6. Tests we'll add

Following CONTRIBUTING.md (row-level invariants > aggregate reconciliation, no `severity='warn'` on known-broken state):

**`refund_fact`**
- `unique` + `not_null` on `refund_id`.
- `not_null` on `order_id`, `amount`, `refunded_at`, `source`.
- `amount > 0` (singular test).

**`order_fact`**
- Singular row-level: per order, `refund_total = sum(refund_fact.amount where order_id = ...)`.
- Singular: `net_revenue = revenue - coalesce(refund_total, 0)` (tautology guard against future drift).
- `severity='warn'` test: count of orders where `refund_total > revenue` (Finance signal, not bug).

**`order_line_fact`**
- Singular row-level: per order, `sum(order_line_fact.refund_amount) = order_fact.refund_total` (within ±$0.01 to account for pro-rata rounding).
- `not_null` on `refund_allocation_method`.

**`stg_refunds`**
- Singular: dedup invariant — no `(order_id, refunded_at_minute)` appears across both Shopify and Stripe in the unified output.

## 7. Reporting / consumer impact

We checked the `reporting/` layer for anything that names `revenue` and would silently change meaning. Current state: nothing in `reporting/` consumes refunds (because they don't exist yet), so we're additive. New reporting models we expect Finance will want:

- `rpt_net_revenue_by_merchant_month`
- `rpt_refunds_by_reason` (if/when reason codes become available — not in current sources)
- `rpt_refunds_by_tender` (joins to `stg_refund_tenders`)

We'd rather Finance own those report shapes than guess at column lists. Spec them; we build them.

## 8. Open questions

1. **Cross-source key:** does upstream Shopify carry the Stripe `refund_id` (or vice versa)? If yes, we drop the time-window heuristic in §3.3.
2. **Reason codes:** none of the three sources carry refund reasons today. Should we ask the upstream loaders to bring them through? Useful for `rpt_refunds_by_reason`.
3. **Partial-refund cadence:** are multi-event refunds against the same line a real scenario (e.g., partial refund today, second partial next week)? Our model handles it, but it changes test expectations.
4. **Currency:** present data is single-currency cents. If multi-currency is on the roadmap, we should add `currency` to `refund_fact` now rather than retrofit.
5. **The DATA-123 reconciliation:** gross revenue ties to Stripe captures of $12,989,886.01 (Q1, non-test) after the recent fix. Once refunds land, Finance's net-revenue number for Q1 will be **lower** by `sum(refund_fact.amount where refunded_at in Q1)`. We should align on what Finance expects that delta to be before deploy, so we have a sanity check.

## 9. Rollout plan (after sign-off)

1. `base/` + `staging/` for the three refund sources, with the dedup logic.
2. `refund_fact` in `dw/`, incremental on `refunded_at`.
3. Update `order_fact` + `order_line_fact` per §3.5–§3.6 and §4.
4. Tests per §6.
5. Spot-check: total Q1 refunds, top-10 refunded orders, allocation method mix.
6. Hand to Finance for parallel validation against their current manual net-revenue calc.
7. Flip the relevant reporting models / dashboards.

Backfill = one `make full`. Daily incremental thereafter.

## 10. What this doc is *not*

- Not a Type-2 history proposal for refund state changes. If a refund gets voided or amended, today we'd see the latest row only. If that becomes a real scenario, it's a follow-up snapshot model — same answer as the Q3-2024 Type-2 question on merchants.
- Not a chargeback model. Stripe disputes / chargebacks are a different upstream and have a different finance treatment (cost of goods sold side, not gross revenue contra). Out of scope here.
- Not a fix to gross-revenue computation. That's DATA-123, separate.
