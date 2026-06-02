# Refund Fact Table — Proposal

**Author:** Ian Buckmaster  
**Status:** Proposal — under review  
**Date:** 2026-06-01  
**Related ticket:** DATA-456

---

## Overview

We have refund data from three source systems: Shopify, Stripe, and an internal point-of-sale (POS) system. Each source records refunds differently — at a different level of detail, with different fields, and with significant overlap between Shopify and Stripe for our online merchants.

This document explains the challenges created by those differences, evaluates two simpler alternatives, and proposes a **refund fact table** (`fact_refunds`) as the right foundation for refund reporting.

---

## The Raw Data

### Shopify refunds — line-item grain

Shopify records one row **per line item refunded**. It is the only source with product-level detail.

| refund_id | order_id | line_item_id | qty_refunded | amount | refunded_at |
|-----------|----------|--------------|--------------|--------|-------------|
| SHF000001 | O000015  | L0000029     | 1            | $367.70 | 2026-02-01 |
| SHF000004 | O005064  | L0009590     | 5            | $1,789.05 | 2026-04-18 |
| SHF000007 | O007544  | L0014230     | 5            | $1,902.85 | 2025-11-21 |

**What Shopify tells us:** which items were returned, how many units, and the exact dollar amount at the line level.

---

### Stripe refunds — order + tender-type grain

Stripe records one row **per payment method (tender type) per order**. An order refunded partly to a card and partly in store credit produces two rows. Stripe has no knowledge of which items were returned.

| refund_id | order_id | tender_type  | amount    | processed_at |
|-----------|----------|--------------|-----------|--------------|
| STR000002 | O000286  | card         | $1,925.22 | 2025-03-09   |
| STR000005 | O005064  | card         | $894.52   | 2026-04-18   |
| STR000006 | O005064  | store_credit | $894.53   | 2026-04-18   |
| STR000008 | O007544  | card         | $951.42   | 2025-11-21   |
| STR000009 | O007544  | store_credit | $951.43   | 2025-11-21   |

**What Stripe tells us:** how the refund was returned to the customer (card vs. store credit), and the total financial settlement. Stripe does not know what was returned — only that money moved.

---

### POS refunds — order grain

The internal point-of-sale system records one row **per order**. There is no tender-type split and no line-item detail.

| refund_id | order_id | amount    | refunded_at |
|-----------|----------|-----------|-------------|
| POS000003 | O009009  | $1,212.11 | 2026-05-11  |

**What POS tells us:** a refund happened and its total amount. Nothing about items or payment method.

---

## The Problems

### Problem 1: Shopify and Stripe record the same event twice

For our merchants who use both Shopify and Stripe (our online Shopify merchants), **every refund appears in both systems**. Shopify tracks what was returned (items); Stripe tracks how the money was returned (tender). They represent the same business event from two angles.

Look at orders O005064 and O007544:

**Order O005064:**
- Shopify records: `SHF000004` — $1,789.05 (5 units of line item L0009590)
- Stripe records: `STR000005` ($894.52 card) + `STR000006` ($894.53 store credit) = **$1,789.05**
- These are the same refund. The amounts match exactly.

**Order O007544:**
- Shopify records: `SHF000007` — $1,902.85 (5 units of line item L0014230)
- Stripe records: `STR000008` ($951.42 card) + `STR000009` ($951.43 store credit) = **$1,902.85**
- Again, the same refund. The split across tender types is Stripe's internal accounting.

**If you naively sum both Shopify and Stripe, you double-count.** A query that unions all refund rows and sums amounts would show $3,578.10 for order O005064 when the true refund was $1,789.05.

---

### Problem 2: Stripe-only refunds have no line-item detail — ever

Order O000286 has a Stripe refund of $1,925.22 (`STR000002`) but **no Shopify record**. This merchant processes payments through Stripe directly, without Shopify as the storefront. There is no line-item-level breakdown of this refund anywhere in any source system — not now, not in the future. Any product-level attribution for this refund would be fabricated.

---

### Problem 3: POS refunds are completely separate

Order O009009 is a point-of-sale transaction. It does not overlap with Shopify or Stripe — they are different merchant channels entirely. The POS system does not record which items were returned, and the $1,212.11 refund amount is the only fact we have.

---

## Approaches We Considered

### Option 1: Add refund amounts directly to the order fact table

The simplest path would be to calculate `total_refund_amount` from all three sources, deduplicate the Shopify/Stripe overlap, and add it as a column on `order_fact`.

**Why this is not enough on its own:**

- `order_fact` is a snapshot of an order's state — it has one row per order. Refunds are a separate business process with their own timestamp, source system, and attributes that matter for analysis (when did the refund happen relative to the order? which source processed it?). Collapsing that into a single column erases information that consumers will eventually need.

- An order can have multiple partial refunds over time. Adding `total_refund_amount` as a single pre-summed column on `order_fact` makes it impossible to answer questions like "how many orders had a refund more than 30 days after fulfillment?" without rebuilding the table.

- Finance and operations teams typically want to query refunds as their own unit — filter by date range, group by source system, trend over time. A column on the order fact is not queryable that way; a fact table is.

Adding `total_refund_amount` to `order_fact` is useful as a convenience column for simple net-revenue calculations, but it should be a downstream derivation from a proper refunds table, not the primary representation.

---

### Option 2: Estimate line-item refund allocations across all sources

Because only Shopify provides line-item data, one approach is to invent line-level refund amounts for Stripe and POS orders by distributing the order-level refund proportionally (by revenue share) or evenly (by line count) across that order's line items.

Using order O009009 as an example: it has two line items.

| line_item_id | qty | unit_price | line_revenue | estimated_refund (even split) |
|--------------|-----|------------|--------------|-------------------------------|
| L0016976     | 3   | $315.31    | $945.93      | $606.06                       |
| L0016977     | 2   | $133.09    | $266.18      | $606.05                       |
| **Total**    |     |            | **$1,212.11** | **$1,212.11**                |

The math works at the order level. But those line-item amounts are invented. We do not know whether the POS customer returned both items, one item, or a partial quantity of either. The same problem applies to all Stripe-only orders.

**Why this approach is risky:**

- Estimated values look identical to measured values in a table. Business users querying `order_line_fact.refund_amount` have no way to tell which rows are exact (Shopify) and which are fabricated (Stripe/POS) unless the documentation is prominent and consistently read — which it will not be.

- Product and category managers making sourcing or pricing decisions based on SKU-level return rates would be working with numbers that do not reflect what customers actually returned.

- Even if you add a flag column like `refund_source = 'distributed_estimate'`, the moment that column is filtered out of a query (intentionally or accidentally), the estimates are treated as facts.

- We cannot make this more accurate later without access to data that doesn't exist. This is not a fixable estimation — it is a permanent fabrication for two of our three refund sources.

If line-item refund detail is needed in the future, the right path is to build a separate `fact_refund_line_items` table populated exclusively from Shopify (where the data is exact), and leave line-item refund columns null or absent for Stripe and POS orders. That table is out of scope for this proposal.

---

## Proposed: `fact_refunds`

### Grain and design philosophy

`fact_refunds` has one row **per unique refund event**, deduplicated across sources. For orders that appear in both Shopify and Stripe (the same real-world refund recorded twice), we keep one row — not two.

This table is the canonical record of "a refund happened." The `order_fact` can join to it for order-level net revenue calculations. The `order_line_fact` can join to it for any analysis scoped to orders that were refunded, even when line-level detail isn't available.

### Schema

| column | type | description |
|--------|------|-------------|
| `refund_id` | varchar | Surrogate key — unique per refund event |
| `order_id` | varchar | FK to `order_fact` |
| `source_system` | varchar | Which system is authoritative: `shopify_stripe`, `stripe_only`, or `pos` |
| `total_refund_amount` | decimal | Total amount refunded in dollars |
| `refunded_at` | timestamp | When the refund was processed |
| `has_line_item_detail` | boolean | True only for Shopify-sourced refunds where item-level breakdown exists in source |
| `shopify_refund_id` | varchar | Source refund ID from Shopify (nullable) |
| `stripe_refund_ids` | varchar | Pipe-separated Stripe refund IDs for this event (nullable) |
| `pos_refund_id` | varchar | Source refund ID from POS (nullable) |

### Deduplication logic

For orders that appear in both Shopify and Stripe, Shopify is the authoritative amount source (the two always match for our merchants, and Shopify provides richer item detail). The Stripe refund IDs are preserved in `stripe_refund_ids` for traceability.

| order_id | source_system   | total_refund_amount | has_line_item_detail | shopify_refund_id | stripe_refund_ids       |
|----------|-----------------|---------------------|----------------------|-------------------|-------------------------|
| O000015  | shopify_stripe  | $367.70             | true                 | SHF000001         | *(none in sample)*      |
| O005064  | shopify_stripe  | $1,789.05           | true                 | SHF000004         | STR000005\|STR000006    |
| O007544  | shopify_stripe  | $1,902.85           | true                 | SHF000007         | STR000008\|STR000009    |
| O000286  | stripe_only     | $1,925.22           | false                | *(null)*          | STR000002               |
| O009009  | pos             | $1,212.11           | false                | *(null)*          | *(null)*                |

Total refund exposure across all orders: **$7,397.93**, with no double-counting.

---

## How `fact_refunds` Is Used with Existing Tables

### Calculating net revenue per order

```sql
SELECT
    o.order_id,
    o.merchant_name,
    o.revenue                                       AS gross_revenue,
    COALESCE(r.total_refund_amount, 0)              AS total_refunds,
    o.revenue - COALESCE(r.total_refund_amount, 0)  AS net_revenue
FROM order_fact AS o
LEFT JOIN fact_refunds AS r ON o.order_id = r.order_id
```

The LEFT JOIN means orders with no refund get `null` → 0 for refunds and show full gross revenue as net. Every order is present; refunds are additive.

---

### Refund rate by merchant or channel

```sql
SELECT
    o.merchant_name,
    COUNT(DISTINCT o.order_id)       AS total_orders,
    COUNT(DISTINCT r.order_id)       AS refunded_orders,
    SUM(r.total_refund_amount)       AS total_refunded,
    SUM(o.revenue)                   AS gross_revenue,
    SUM(r.total_refund_amount)
        / NULLIF(SUM(o.revenue), 0)  AS refund_rate
FROM order_fact AS o
LEFT JOIN fact_refunds AS r ON o.order_id = r.order_id
GROUP BY o.merchant_name
```

This gives a clean refund rate per merchant with no risk of double-counting, regardless of which source system each merchant uses.

---

### Refund trends over time

```sql
SELECT
    DATE_TRUNC('month', r.refunded_at) AS refund_month,
    r.source_system,
    COUNT(*)                           AS refund_count,
    SUM(r.total_refund_amount)         AS total_refunded
FROM fact_refunds AS r
GROUP BY 1, 2
ORDER BY 1, 2
```

Because refunds are their own table with their own timestamp, time-series analysis on refunds is straightforward. This is not possible when refund data is collapsed into the order fact.

---

### Joining to order line items (order-scoped, not line-scoped)

```sql
-- Which products appear most often on refunded orders?
SELECT
    l.product_id,
    COUNT(DISTINCT l.order_id)  AS orders_with_product,
    COUNT(DISTINCT r.order_id)  AS refunded_orders_with_product
FROM order_line_fact AS l
LEFT JOIN fact_refunds AS r ON l.order_id = r.order_id
GROUP BY l.product_id
```

This surfaces product-refund correlation without fabricating product-level refund amounts. It answers "which products appear on refunded orders?" not "how much was refunded due to this product?" — an honest distinction given our data.

---

## What This Table Does Not Solve

`fact_refunds` is an order-grain table. It cannot answer questions that require knowing **which specific line items were returned** — for example, the refund amount attributed to a particular SKU on a Stripe-only or POS order. That information simply does not exist in those source systems.

For Shopify-sourced refunds, the source data does contain that line-level breakdown. If a concrete business need for product-level refund attribution emerges, a `fact_refund_line_items` table scoped to Shopify orders only would be the right extension — with explicit acknowledgment that it covers Shopify orders only and that Stripe-only and POS refunds would be excluded, not estimated.

---

## Summary

| | Option 1: Column on order_fact | Option 2: Estimated line allocations | **Proposed: fact_refunds** |
|---|---|---|---|
| Handles Shopify/Stripe overlap correctly | With care | With care | Yes — by design |
| Supports time-series refund analysis | No | No | Yes |
| Supports multiple refunds per order | No | No | Yes |
| Contains only measured (non-fabricated) values | Yes | **No** | Yes |
| Joinable to order_fact for net revenue | Yes | Indirectly | Yes |
| Joinable to order_line_fact | N/A | Yes (but estimated) | Yes (order-scoped only) |
| Can be extended with line detail later | No | Already conflated | Yes — via a separate line table |

The refund fact table gives us an accurate, deduplicated, time-aware record of every refund across all three source systems. It composes cleanly with `order_fact` for financial reporting and with `order_line_fact` for product analysis — without requiring us to invent data we don't have.
