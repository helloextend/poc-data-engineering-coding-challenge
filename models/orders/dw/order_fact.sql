{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH order_lines AS (
    SELECT
        order_id
        , count(line_item_id) AS line_count
        , sum(quantity) AS total_quantity
        , sum(quantity * unit_price) AS revenue
        , sum(
            CASE
                WHEN line_status = 'cancelled' THEN quantity * unit_price
                ELSE 0
            END
        ) AS cancelled_revenue
    FROM {{ ref('stg_line_items') }}
    GROUP BY order_id
)

, shopify_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount_shopify
    FROM {{ ref('stg_refunds_shopify') }}
    GROUP BY order_id
)

, stripe_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount_stripe
    FROM {{ ref('stg_refunds_stripe') }}
    GROUP BY order_id
)

, pos_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount_internal_pos
    FROM {{ ref('stg_refunds_internal_pos') }}
    GROUP BY order_id
)

, shipment_agg AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
        , min(shipped_at) AS shipped_at
    FROM {{ ref('stg_shipments') }}
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
        , sa.shipped_at
        , coalesce(sa.shipment_count, 0) AS shipment_count
        , coalesce(ol.line_count, 0) AS line_count
        , coalesce(ol.total_quantity, 0) AS total_quantity
        , coalesce(ol.revenue, 0) AS revenue
        , coalesce(ol.cancelled_revenue, 0) AS cancelled_revenue
        , coalesce(shf.refund_amount_shopify, 0) AS refund_amount_shopify
        , coalesce(str.refund_amount_stripe, 0) AS refund_amount_stripe
        , coalesce(pos.refund_amount_internal_pos, 0) AS refund_amount_internal_pos
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN order_lines AS ol
        ON o.order_id = ol.order_id
    LEFT JOIN shipment_agg AS sa
        ON o.order_id = sa.order_id
    LEFT JOIN shopify_refunds AS shf
        ON o.order_id = shf.order_id
    LEFT JOIN stripe_refunds AS str
        ON o.order_id = str.order_id
    LEFT JOIN pos_refunds AS pos
        ON o.order_id = pos.order_id
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
    , cancelled_revenue
    , refund_amount_shopify
    , refund_amount_stripe
    , refund_amount_internal_pos
    , refund_amount_shopify + refund_amount_stripe + refund_amount_internal_pos AS refund_amount
    , revenue - cancelled_revenue
        - (refund_amount_shopify + refund_amount_stripe + refund_amount_internal_pos) AS net_revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM enriched
{% if is_incremental() %}
    WHERE ordered_at >= {{ get_incremental_value('updated_at_dwh') }}
{% endif %}
