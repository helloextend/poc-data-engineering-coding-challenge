{{ config(materialized='view') }}

SELECT *
FROM {{ source('raw', 'refunds_stripe') }}
