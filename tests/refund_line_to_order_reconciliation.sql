{{ config(severity='error') }}

-- Reconciles per-order sum of order_line_fact.cash_refund_amount against
-- order_fact.cash_refund_amount. Same invariant DATA-123 broke for revenue
-- (sum-of-lines ≠ order total), now defended for cash refunds.
-- Returns rows when any order's discrepancy exceeds $0.01.

WITH line_totals AS (
    SELECT
        order_id
        , sum(cash_refund_amount) AS line_cash_refund_total
    FROM {{ ref('order_line_fact') }}
    GROUP BY order_id
)

, order_totals AS (
    SELECT
        order_id
        , cash_refund_amount AS order_cash_refund
    FROM {{ ref('order_fact') }}
)

SELECT
    o.order_id
    , o.order_cash_refund
    , coalesce(l.line_cash_refund_total, 0) AS line_cash_refund_total
    , o.order_cash_refund - coalesce(l.line_cash_refund_total, 0) AS discrepancy
FROM order_totals AS o
LEFT JOIN line_totals AS l
    ON o.order_id = l.order_id
WHERE abs(o.order_cash_refund - coalesce(l.line_cash_refund_total, 0)) > 0.01
