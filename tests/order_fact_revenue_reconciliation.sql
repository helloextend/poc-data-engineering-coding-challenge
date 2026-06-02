{{ config(severity='error') }}

-- Reconciles order_fact totals against summed raw line items for non-test orders.
-- Returns rows when anything is broken (revenue/quantity/line_count).

with fact_total as (
    select
        sum(revenue) as total_revenue
        , sum(total_quantity) as total_quantity
        , sum(line_count) as total_line_count
    from {{ ref('order_fact') }}
    where coalesce(lower(cast(is_test as varchar)), 'false') != 'true'
)

, line_total as (
    select
        sum(li.quantity * li.unit_price) as expected_revenue
        , sum(li.quantity) as expected_quantity
        , count(distinct li.line_item_id) as expected_line_count
    from {{ ref('stg_line_items') }} as li
    inner join {{ ref('stg_orders') }} as o
        on li.order_id = o.order_id
    where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
)

select
    f.total_revenue as fact_revenue
    , l.expected_revenue as expected_revenue
    , l.expected_revenue - f.total_revenue as revenue_discrepancy
    , f.total_quantity as fact_quantity
    , l.expected_quantity as expected_quantity
    , l.expected_quantity - f.total_quantity as quantity_discrepancy
    , f.total_line_count as fact_line_count
    , l.expected_line_count as expected_line_count
    , l.expected_line_count - f.total_line_count as line_count_discrepancy
from fact_total as f
cross join line_total as l
where
    abs(l.expected_revenue - f.total_revenue) > 1
    OR (l.expected_quantity - f.total_quantity) != 0
    OR (l.expected_line_count - f.total_line_count) != 0
