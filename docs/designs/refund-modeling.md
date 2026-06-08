# Refund modeling — net revenue for finance

**Author:** Data engineering (draft)
**Status:** Proposed
**Last updated:** 2026-06-08
**Related:** DATA-456, DATA-145, `order_fact`, `order_line_fact`

## Context

Finance needs **net revenue** while `order_fact.revenue` remains **gross**
(sum of `quantity × unit_price` across line items, no tax, shipping, discounts,
or refunds — see `orders_dw.md`).

Three refund sources exist in `raw/` but are not yet loaded into the DW:


| Source                 | Grain                         | Line detail | Key fields                                                                |
| ---------------------- | ----------------------------- | ----------- | ------------------------------------------------------------------------- |
| `refunds_shopify`      | Refund event × line           | Yes         | `line_item_id`, `qty_refunded`, `amount_in_cents`, `refunded_at`          |
| `refunds_stripe`       | Refund event × order × tender | No          | `tender_type` (`card`, `store_credit`), `amount_in_cents`, `processed_at` |
| `refunds_internal_pos` | Refund event × order          | No          | `amount_in_cents`, `refunded_at`                                          |


The Q3 2024 orders redesign (`2024-Q3-orders-redesign.md`) intentionally scoped
refunds out of `order_fact` and called for a separate `refund_fact` so refund
logic does not get tangled with order status and gross revenue reasoning again.

---

## Observations

### Merchant payment and refund sources overlap

A single merchant can operate across more than one payment/refund channel.
In practice, a merchant may use **internal POS** alongside **Shopify** or
**Stripe** — not every merchant uses a single source.

Refund events therefore arrive at different grains and from different systems
for the same underlying business activity. Naively summing all three sources
per order will over-count refunds where the same refund is recorded in both an
operational system (Shopify) and a payment rail (Stripe).

Example from sample data — order `O005064`:

- Shopify records a line-level refund (`SHF000004`, line `L0009590`, 178,905 cents).
- Stripe records the same refund split across tenders (`STR000005` card 89,452 +
`STR000006` store_credit 89,453 = 178,905 cents).

These are one refund, not two.

### Stripe tender splits are one refund, not two

Stripe refunds can appear as multiple rows per order when the refund is paid
out through more than one tender (e.g. `card` + `store_credit`). When rolling
up to order-level refund totals, **sum Stripe rows per order** — but interpret
card + store_credit on the same refund episode as components of a **single**
refund, not independent refunds to add on top of each other.

The same care applies to POS: one order may have one POS refund row representing
the full order-level amount.

### Source grains differ

- **Shopify** is the only source with native **line-level** detail
(`line_item_id`, `qty_refunded`). Partial line refunds are possible
(`qty_refunded` < line `quantity`).
- **Stripe** and **internal POS** are **order-level** only — no `line_item_id`.
Per-line refund amounts on `order_line_fact` require an allocation rule for
these sources.

### Gross revenue contract is already fixed

`order_fact.revenue` and `order_line_fact.line_revenue` should stay gross.
Net figures belong in new columns (`refund_amount`, `net_revenue`, etc.) so
existing consumers (e.g. `daily_revenue`) do not change behavior silently.

---

## Proposed modeling approach

### 1. Staging and unified refund events (Recommended)

Ingest each raw source into its own staging model, then union into a single
refund-events layer at **one row per `refund_id` + `source_system`**.

Normalize to a common shape:

- `refund_id`, `source_system`, `order_id`
- `line_item_id` (nullable)
- `qty_refunded` (nullable)
- `refund_amount` (dollars; convert from cents)
- `refunded_at` (map Stripe `processed_at` here)
- `tender_type` (Stripe only)
- `refund_grain` (`line` vs `order`)

Do not deduplicate in staging — keep every source event for audit and
reconciliation. Materialize as a `**refund_fact**` at refund-event grain.



### 2. Order-level reconciliation

Before rolling up to `order_fact`, derive an `**order_refund_summary**`
(one row per `order_id`) with a reconciled `gross_refund_amount`.

Suggested source-of-truth rules by merchant/refund pattern:


| Pattern           | Authoritative source for refund total                           | Notes                                      |
| ----------------- | --------------------------------------------------------------- | ------------------------------------------ |
| Shopify-only      | Sum Shopify events per order                                    | Line detail available natively             |
| Stripe-only       | Sum Stripe tenders per order                                    | Card + store_credit = one refund           |
| Internal POS-only | Sum POS events per order                                        | Order-level only                           |
| Shopify + Stripe  | Shopify for allocation total; Stripe for payment reconciliation | Do not add Stripe totals on top of Shopify |


Flag orders where cross-source totals do not reconcile (e.g. Shopify amount ≠
sum of Stripe tenders for the same refund episode).

### 3. Line-level allocation for `order_line_fact`


| Refund origin                    | Allocation                                                                             |
| -------------------------------- | -------------------------------------------------------------------------------------- |
| Shopify line refunds             | Direct — attach `refund_amount` and `qty_refunded` to matching `line_item_id`          |
| Stripe / POS order-level refunds | Allocate order refund to lines via a documented rule (e.g. pro-rata by `line_revenue`) |


For Shopify + Stripe orders, allocate from **Shopify line events only**; do not
re-allocate from Stripe payment totals.

Each line ends up with:

- `line_refund_amount`
- `net_line_revenue` = `line_revenue − line_refund_amount`

### 4. Surface on existing facts

`**order_fact`** (grain unchanged: one row per `order_id`):


| Column                                          | Definition                             |
| ----------------------------------------------- | -------------------------------------- |
| `refund_amount`                                 | Reconciled total refunds for the order |
| `net_revenue`                                   | `revenue − refund_amount`              |
| optionally `first_refunded_at`, `refund_source` | Audit / reporting                      |


`**order_line_fact**` (grain unchanged: one row per `line_item_id`):


| Column               | Definition                                   |
| -------------------- | -------------------------------------------- |
| `line_refund_amount` | Direct (Shopify) or allocated (Stripe / POS) |
| `net_line_revenue`   | `line_revenue − line_refund_amount`          |


### 5. Data flow

```
raw refunds (shopify, stripe, internal_pos)
  → staging per source
  → refund_fact (event grain, all sources preserved)
  → order_refund_summary (reconciled order totals)
  → line refund allocations
  → order_fact (+ refund_amount, net_revenue)
  → order_line_fact (+ line_refund_amount, net_line_revenue)
```

---

## Guardrails

1. **No double-counting** — merchant-pattern reconciliation rules; flag mismatches.
2. **Test orders** — exclude consistently (same rule as `daily_revenue`).
3. **Partial refunds** — honor Shopify `qty_refunded`; validate amount vs qty × unit price.
4. **Reconciliation tests** — `sum(line_refund_amount)` per order ≈ `order_fact.refund_amount`;
  `sum(net_line_revenue)` per order ≈ `order_fact.net_revenue`.
5. **Incremental refresh** — refund models keyed on `refunded_at` / `processed_at`;
  facts updated when refunds arrive after the original order load.

---

## Out of scope (for now)

- Tender-level reporting (card vs store_credit) — keep on `refund_fact`, not `order_fact`
- Tax, shipping, discounts in net revenue — follow the same scope as gross `revenue` unless finance expands the definition
- Changing `order_status = 'refunded'` semantics — keep status and refund/revenue logic separate

---

## Open questions

- Confirm merchant-to-source mapping (which merchants are Shopify-only vs Stripe-only vs POS vs multi-source) — may live on `lkp_merchants` or be inferred from which sources emit events per order.
- Choose default line allocation method for order-level refunds (pro-rata by `line_revenue` is the suggested default).
- Whether `daily_revenue` should move to `net_revenue` or expose both gross and net.

