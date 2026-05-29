{{ config(severity='error') }}

-- Reconciles total order_fact.revenue against summed line items for non-test orders.
-- Returns rows when the discrepancy exceeds $1 — that is, when something is broken.

with fact_total as (
    select sum(revenue) as total_revenue
    from {{ ref('order_fact') }}
    where coalesce(lower(cast(is_test as varchar)), 'false') != 'true'
)

, line_total as (
    select sum(li.quantity * li.unit_price) as expected_revenue
    from {{ ref('stg_line_items') }} as li
    inner join {{ ref('stg_orders') }} as o
        on li.order_id = o.order_id
    where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
)

select
    f.total_revenue
    , l.expected_revenue
    , l.expected_revenue - f.total_revenue as discrepancy
from fact_total as f
cross join line_total as l
where abs(l.expected_revenue - f.total_revenue) > 1
