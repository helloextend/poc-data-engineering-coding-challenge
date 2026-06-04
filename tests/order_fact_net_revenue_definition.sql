-- Tautology guard: net_revenue must equal revenue - refund_total at row level.
-- Catches future drift if someone changes one column's formula and not the other.

SELECT
    order_id
    , revenue
    , refund_total
    , net_revenue
    , revenue - refund_total AS expected_net_revenue
FROM {{ ref('order_fact') }}
WHERE abs(net_revenue - (revenue - refund_total)) > 0.01
