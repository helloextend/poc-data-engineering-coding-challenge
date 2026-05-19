{{ config(
    materialized='incremental',
    unique_key='line_item_id'
) }}

-- See order_fact for the same caveat: refund columns on already-loaded rows
-- go stale under the current incremental strategy. Run `make full` to keep
-- per-line refund totals in sync. Canonical refund data lives in
-- refund_line_fact.

WITH line_refunds AS (
    SELECT
        line_item_id
        , sum(cash_refund_amount) AS cash_refund_amount
    FROM {{ ref('refund_line_fact') }}
    GROUP BY line_item_id
)

SELECT
    li.line_item_id
    , li.order_id
    , li.product_id
    , li.quantity
    , li.unit_price
    , li.quantity * li.unit_price AS line_revenue
    , coalesce(lr.cash_refund_amount, 0) AS cash_refund_amount
    , li.quantity * li.unit_price - coalesce(lr.cash_refund_amount, 0) AS net_line_revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM {{ ref('stg_line_items') }} AS li
LEFT JOIN line_refunds AS lr
    ON li.line_item_id = lr.line_item_id

{% if is_incremental() %}
    WHERE li.line_item_id NOT IN (SELECT t.line_item_id FROM {{ this }} AS t)
{% endif %}
