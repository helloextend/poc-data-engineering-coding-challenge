{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH shipment_lines AS (
    SELECT
        sl.shipment_id
        , sl.line_item_id
        , sl.quantity_shipped
        , li.unit_price
    FROM {{ ref('stg_shipment_line_items') }} AS sl
    INNER JOIN {{ ref('stg_line_items') }} AS li
        ON sl.line_item_id = li.line_item_id
)

, joined AS (
    SELECT
        o.order_id
        , o.merchant_id
        , o.customer_id
        , o.order_status
        , o.is_test
        , o.ordered_at
        , o.paid_at
        , s.shipment_id
        , s.shipped_at
        , sl.line_item_id
        , sl.quantity_shipped
        , sl.unit_price
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN {{ ref('stg_shipments') }} AS s
        ON o.order_id = s.order_id
    LEFT JOIN shipment_lines AS sl
        ON s.shipment_id = sl.shipment_id
)

, shipment_totals AS (
    -- aggregated to one row per (order, shipment)
    SELECT
        order_id
        , merchant_id
        , customer_id
        , order_status
        , is_test
        , ordered_at
        , paid_at
        , shipment_id
        , shipped_at
        , count(DISTINCT line_item_id) AS line_count
        , sum(quantity_shipped) AS total_quantity
    FROM joined
    GROUP BY order_id, merchant_id, customer_id, order_status, is_test, ordered_at, paid_at, shipment_id, shipped_at
)

, order_revenue AS (
    SELECT
        li.order_id
        , sum(li.quantity * li.unit_price) AS revenue
    FROM {{ ref('stg_line_items') }} AS li
    GROUP BY li.order_id
)

, shipment_counts AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
    FROM shipment_totals
    GROUP BY order_id
)

, enriched AS (
    SELECT
        st.order_id
        , st.merchant_id
        , m.merchant_name
        , st.customer_id
        , m.customer_type
        , st.order_status
        , st.is_test
        , st.ordered_at
        , st.paid_at
        , st.shipped_at
        , sc.shipment_count
        , st.line_count
        , st.total_quantity
        , ol.revenue
    FROM shipment_totals AS st
    LEFT JOIN order_revenue AS ol
        ON st.order_id = ol.order_id
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON st.merchant_id = m.merchant_id
    LEFT JOIN shipment_counts AS sc
        ON st.order_id = sc.order_id
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
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM enriched
{% if is_incremental() %}
    WHERE ordered_at >= {{ get_incremental_value('updated_at_dwh') }}
{% endif %}
-- dedupe to one row per order (orders can have multiple shipments)
QUALIFY row_number() OVER (PARTITION BY order_id ORDER BY shipped_at) = 1
