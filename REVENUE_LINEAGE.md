# Revenue Field Lineage: From Raw to order_fact

## Overview
This document traces the complete lineage of the **Revenue** field in the `order_fact` table back to its source raw data. The journey spans 3 transformation layers: Raw → Base → Staging → DW.

---

## Layer 1: RAW LAYER (Source Data)

### Primary Tables:
1. **raw.line_items** (CSVs: raw/line_items.csv)
   - `line_item_id` → identifier
   - `order_id` → join key
   - `product_id` → product identifier
   - `quantity` → units per line item
   - **`unit_price_in_cents`** ⭐ **[REVENUE SOURCE #1]** - Unit cost in cents
   - `line_status` → fulfillment status

2. **raw.shipment_line_items** (CSVs: raw/shipment_line_items.csv)
   - `shipment_id` → shipment identifier
   - `line_item_id` → join key to line_items
   - **`quantity_shipped`** ⭐ **[REVENUE SOURCE #2]** - Actual quantity shipped

3. **raw.orders** (CSVs: raw/orders.csv)
   - `order_id` → primary identifier
   - `merchant_id`, `customer_id` → dimensional data
   - `order_status`, `is_test` → metadata
   - `ordered_at`, `paid_at` → temporal data

4. **raw.shipments** (CSVs: raw/shipments.csv)
   - `shipment_id` → primary identifier
   - `order_id` → join key
   - `shipped_at` → temporal data

### Revenue Calculation at Raw Layer:
```
Raw Revenue Components:
- unit_price_in_cents (from line_items)
- quantity_shipped (from shipment_line_items)
```

---

## Layer 2: BASE LAYER (Cleaning & Transformation)

### Data Transformations:

#### [base_orders](models/orders/base/base_orders.sql)
```sql
SELECT * FROM {{ source('raw', 'orders') }}
```
**Purpose:** Passthrough of raw orders data  
**Output:** All columns from raw.orders unchanged

---

#### [base_line_items](models/orders/base/base_line_items.sql)
```sql
SELECT *
FROM {{ source('raw', 'line_items') }}
```
**Purpose:** Passthrough of raw line_items data  
**Output:** All columns from raw.line_items unchanged

**Key Transformation:**
- `unit_price_in_cents` → stays as-is for now (transformation happens later in staging)

---

#### [base_shipments](models/orders/base/base_shipments.sql)
```sql
SELECT *
FROM {{ source('raw', 'shipments') }}
```
**Purpose:** Passthrough of raw shipments data  
**Output:** All columns from raw.shipments unchanged

---

#### [base_shipment_line_items](models/orders/base/base_shipment_line_items.sql)
```sql
SELECT *
FROM {{ source('raw', 'shipment_line_items') }}
```
**Purpose:** Passthrough of raw shipment_line_items data  
**Output:** All columns from raw.shipment_line_items unchanged

---

## Layer 3: STAGING LAYER (Standardization & Business Logic)

### Data Transformations:

#### [stg_orders](models/orders/staging/stg_orders.sql)
```sql
SELECT
    order_id,
    merchant_id,
    customer_id,
    order_status,
    is_test,
    CAST(ordered_at AS timestamp) AS ordered_at,
    CAST(paid_at AS timestamp) AS paid_at
FROM {{ ref('base_orders') }}
```
**Purpose:** Standardize timestamps  
**Output:** Order dimension data with proper timestamp types

---

#### [stg_line_items](models/orders/staging/stg_line_items.sql)
```sql
SELECT
    line_item_id,
    order_id,
    product_id,
    quantity,
    unit_price_in_cents / 100.0 AS unit_price,  ⭐ **[KEY CONVERSION: CENTS → DOLLARS]**
    line_status
FROM {{ ref('base_line_items') }}
```
**Purpose:** Convert unit price from cents to dollars  
**Key Transformation:**
- `unit_price_in_cents / 100.0 → unit_price` ⭐ **[REVENUE TRANSFORMATION #1]**

---

#### [stg_shipments](models/orders/staging/stg_shipments.sql)
```sql
SELECT
    shipment_id,
    order_id,
    CAST(shipped_at AS timestamp) AS shipped_at
FROM {{ ref('base_shipments') }}
```
**Purpose:** Standardize shipment data  
**Output:** Shipment dimension with proper timestamp type

---

#### [stg_shipment_line_items](models/orders/staging/stg_shipment_line_items.sql)
```sql
SELECT *
FROM {{ ref('base_shipment_line_items') }}
```
**Purpose:** Passthrough of shipment line items  
**Output:** All columns (shipment_id, line_item_id, quantity_shipped)

---

## Layer 4: DW LAYER (Fact Table)

### [order_line_fact](models/orders/dw/order_line_fact.sql)
This is an intermediate fact table that calculates line-level revenue:

```sql
SELECT
    li.line_item_id,
    li.order_id,
    li.product_id,
    li.quantity,
    li.unit_price,
    li.quantity * li.unit_price AS line_revenue,  ⭐ **[REVENUE CALCULATION #1]**
    current_timestamp AS created_at_dwh,
    current_timestamp AS updated_at_dwh
FROM {{ ref('stg_line_items') }} AS li
```
**Key Calculation:**
- `quantity * unit_price → line_revenue` ⭐ **[FIRST REVENUE AGGREGATION]**

---

### [order_fact](models/orders/dw/order_fact.sql) - PRIMARY FACT TABLE
This is where the final Revenue field is created:

```sql
-- CTE 1: shipment_lines
WITH shipment_lines AS (
    SELECT
        sl.shipment_id,
        sl.line_item_id,
        sl.quantity_shipped,  ⭐ from stg_shipment_line_items
        li.unit_price        ⭐ from stg_line_items
    FROM {{ ref('stg_shipment_line_items') }} AS sl
    INNER JOIN {{ ref('stg_line_items') }} AS li
        ON sl.line_item_id = li.line_item_id
)

-- CTE 2-3: Build joined shipment facts

-- CTE 4: shipment_totals - KEY AGGREGATION POINT
, shipment_totals AS (
    SELECT
        order_id,
        merchant_id,
        customer_id,
        order_status,
        is_test,
        ordered_at,
        paid_at,
        shipment_id,
        shipped_at,
        count(DISTINCT line_item_id) AS line_count,
        sum(quantity_shipped) AS total_quantity,
        sum(quantity_shipped * unit_price) AS shipment_revenue  ⭐ **[REVENUE CALCULATION #2]**
    FROM joined
    GROUP BY order_id, merchant_id, customer_id, order_status, is_test, ordered_at, paid_at, shipment_id, shipped_at
)

-- CTE 5: enriched
, enriched AS (
    SELECT
        st.order_id,
        st.merchant_id,
        m.merchant_name,
        st.customer_id,
        m.customer_type,
        st.order_status,
        st.is_test,
        st.ordered_at,
        st.paid_at,
        st.shipped_at,
        sc.shipment_count,
        st.line_count,
        st.total_quantity,
        st.shipment_revenue AS revenue  ⭐ **[FINAL REVENUE FIELD]**
    FROM shipment_totals AS st
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON st.merchant_id = m.merchant_id
    LEFT JOIN shipment_counts AS sc
        ON st.order_id = sc.order_id
)

SELECT
    order_id,
    merchant_id,
    merchant_name,
    customer_id,
    customer_type,
    order_status,
    is_test,
    ordered_at,
    paid_at,
    shipped_at,
    shipment_count,
    line_count,
    total_quantity,
    revenue  ⭐ **[OUTPUT FIELD]**
    ...
```

**Key Calculation:**
- `sum(quantity_shipped * unit_price) → shipment_revenue → revenue` ⭐ **[FINAL REVENUE AGGREGATION]**

---

## Complete Lineage Flow Diagram

```
RAW LAYER
├── raw.orders (order_id, merchant_id, customer_id, ...)
├── raw.line_items (line_item_id, order_id, quantity, unit_price_in_cents ⭐)
├── raw.shipments (shipment_id, order_id, shipped_at)
└── raw.shipment_line_items (shipment_id, line_item_id, quantity_shipped ⭐)

    ↓ (passthrough transformations)

BASE LAYER
├── base_orders
├── base_line_items (unit_price_in_cents)
├── base_shipments
└── base_shipment_line_items (quantity_shipped)

    ↓ (standardization & unit conversion)

STAGING LAYER
├── stg_orders
├── stg_line_items (unit_price_in_cents / 100.0 → unit_price ⭐⭐)
├── stg_shipments
└── stg_shipment_line_items (quantity_shipped)

    ↓ (aggregation & enrichment)

DW LAYER
├── order_line_fact (quantity * unit_price → line_revenue)
└── order_fact
    └── revenue: sum(quantity_shipped * unit_price) ⭐⭐⭐
```

---

## Revenue Calculation Summary

### Step-by-Step Calculation:

1. **Raw Source Data:**
   - `unit_price_in_cents` from raw.line_items
   - `quantity_shipped` from raw.shipment_line_items

2. **Base Layer (Layer 2):**
   - Data passes through unchanged (views)

3. **Staging Layer (Layer 3) - CRITICAL TRANSFORMATION:**
   - `unit_price_in_cents / 100.0 = unit_price` (convert to dollars)
   - `quantity_shipped` remains as-is

4. **DW Layer (Layer 4) - FACT CALCULATION:**
   - For each shipped line: `quantity_shipped × unit_price`
   - Aggregate by shipment: `SUM(quantity_shipped × unit_price) = shipment_revenue`
   - Final output field: `revenue`

### Example Calculation:
```
Raw Data:
  line_item: unit_price_in_cents = 1640 (i.e., $16.40)
  shipment_line: quantity_shipped = 5

Staging:
  unit_price = 1640 / 100 = 16.40

order_fact Revenue:
  revenue = 5 × 16.40 = $82.00
```

---

## Data Flow Summary Table

| Layer | Model | Type | Input | Transformation | Output |
|-------|-------|------|-------|-----------------|--------|
| RAW | raw.line_items | CSV | - | - | unit_price_in_cents |
| RAW | raw.shipment_line_items | CSV | - | - | quantity_shipped |
| BASE | base_line_items | View | raw.line_items | Passthrough | unit_price_in_cents |
| BASE | base_shipment_line_items | View | raw.shipment_line_items | Passthrough | quantity_shipped |
| STAGING | stg_line_items | View | base_line_items | ÷100 conversion | unit_price (dollars) |
| STAGING | stg_shipment_line_items | View | base_shipment_line_items | Passthrough | quantity_shipped |
| DW | order_fact | Incremental | stg_line_items + stg_shipment_line_items | qty × price, SUM by order | revenue |

---

## Key Observations

1. **Revenue Source:** The `revenue` field is **derived** from two raw fields:
   - `unit_price_in_cents` (line item cost)
   - `quantity_shipped` (actual quantity shipped)

2. **Critical Transformation:** The only data transformation of revenue-related fields happens in the **staging layer** where `unit_price_in_cents` is converted to dollars (÷100).

3. **Aggregation Point:** Revenue is **aggregated at the shipment level** in `order_fact`:
   - Multiple line items per shipment
   - Multiple shipments per order
   - Final `revenue` = SUM of all shipped quantities × their respective unit prices

4. **Materialization:**
   - Base layer: All views (no materialization)
   - Staging layer: All views (no materialization)
   - DW layer: `order_fact` is **incremental** (unique_key: order_id)

5. **Test Filter:** The reporting layer (`daily_revenue`) filters out test orders: `is_test != 'true'`

---

## Related Models

- **order_line_fact:** Line-item level revenue facts
- **daily_revenue:** (Reporting layer) Aggregated daily revenue by date
- **lkp_merchants:** Dimension lookup for merchant enrichment

