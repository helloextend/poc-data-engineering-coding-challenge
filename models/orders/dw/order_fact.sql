{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

-- Note on refund columns: refunds usually post AFTER ordered_at, so in
-- incremental mode the refund_* / net_revenue columns on already-loaded
-- rows can go stale. Run `make full` periodically (or switch to a refund-
-- aware incremental strategy) to keep the denormalized refund totals in
-- sync. The canonical refund data always lives in refund_fact.

WITH order_revenue AS (
    -- Revenue at the order grain comes from line items, per the
    -- `order_fact_revenue` doc: sum(quantity * unit_price), gross of
    -- refunds. Includes orders that have not shipped yet.
    SELECT
        order_id
        , count(1) AS line_count
        , sum(quantity) AS total_quantity
        , sum(quantity * unit_price) AS revenue
    FROM {{ ref('stg_line_items') }}
    GROUP BY order_id
)

, order_shipments AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
        , min(shipped_at) AS shipped_at
    FROM {{ ref('stg_shipments') }}
    GROUP BY order_id
)

, order_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount
        , sum(cash_refund_amount) AS cash_refund_amount
        , sum(store_credit_amount) AS store_credit_issued
    FROM {{ ref('refund_fact') }}
    GROUP BY order_id
)

, enriched AS (
    SELECT
        o.order_id
        , o.merchant_id
        , m.merchant_name
        , o.customer_id
        , m.customer_type
        , o.order_status
        , o.is_test
        , o.ordered_at
        , o.paid_at
        , s.shipped_at
        , coalesce(s.shipment_count, 0) AS shipment_count
        , r.line_count
        , r.total_quantity
        , r.revenue
        , coalesce(rf.refund_amount, 0) AS refund_amount
        , coalesce(rf.cash_refund_amount, 0) AS cash_refund_amount
        , coalesce(rf.store_credit_issued, 0) AS store_credit_issued
        , r.revenue - coalesce(rf.cash_refund_amount, 0) AS net_revenue
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN order_revenue AS r
        ON o.order_id = r.order_id
    LEFT JOIN order_shipments AS s
        ON o.order_id = s.order_id
    LEFT JOIN order_refunds AS rf
        ON o.order_id = rf.order_id
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON o.merchant_id = m.merchant_id
)

SELECT
    order_id
    , merchant_id
    , merchant_name
    , customer_id
    , customer_type
    , order_status
    , is_test
    , ordered_at
    , paid_at
    , shipped_at
    , shipment_count
    , line_count
    , total_quantity
    , revenue
    , refund_amount
    , cash_refund_amount
    , store_credit_issued
    , net_revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM enriched
{% if is_incremental() %}
    WHERE ordered_at >= {{ get_incremental_value('updated_at_dwh') }}
{% endif %}
