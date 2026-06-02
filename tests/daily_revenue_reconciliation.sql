{{ config(severity='error') }}

-- Reconciles daily_revenue rollup against summed raw line item revenue.
-- Returns rows when daily totals by order_date do not match.

with actual as (
    select
        order_date,
        daily_revenue,
        orders
    from {{ ref('daily_revenue') }}
),

expected as (
    select
        cast(o.ordered_at as date) as order_date,
        sum(li.quantity * li.unit_price_in_cents) / 100.0 as expected_daily_revenue,
        count(distinct o.order_id) as expected_orders
    from {{ source('raw', 'line_items') }} as li
    inner join {{ source('raw', 'orders') }} as o
        on li.order_id = o.order_id
    where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
    group by 1
)

select
    a.order_date,
    a.daily_revenue as fact_daily_revenue,
    e.expected_daily_revenue,
    a.orders as fact_orders,
    e.expected_orders,
    e.expected_daily_revenue - a.daily_revenue as revenue_discrepancy
from actual as a
inner join expected as e
    on a.order_date = e.order_date
where
    abs(e.expected_daily_revenue - a.daily_revenue) > 1
    OR e.expected_orders != a.orders

