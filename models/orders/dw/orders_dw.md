{% docs order_fact_revenue %}
Revenue per order in dollars. Defined as the sum of `quantity * unit_price` across
the order's line items, **gross of refunds, no tax, no shipping, no discounts**.
Refunds are loaded separately and not subtracted here.
{% enddocs %}

{% docs order_fact_cancelled_revenue %}
Revenue from line items with `line_status = cancelled`. Applies across order statuses
(e.g. fully `cancelled` orders and `shipped` orders with individually cancelled lines).
{% enddocs %}

{% docs order_fact_refund_amount %}
Total payment refunds in dollars, summed across Shopify (line-level), Stripe
(order-level), and internal POS (order-level) sources.
{% enddocs %}

{% docs order_fact_net_revenue %}
Recognized revenue after cancellations and payment refunds:
`revenue - cancelled_revenue - refund_amount`.
{% enddocs %}
