-- 20260604000000_office_pos_sales_events.sql
--
-- Office read contract for POS sales reconciliation.
--
-- This is additive and read-only. It preserves the existing
-- v_store_daily_sales contract while exposing event-level sales facts in the
-- three Office buckets: cash / card / pay. Cancellation and refund events are
-- append-only facts for Office import; POS rows are not mutated by Office.

create or replace function public.office_payment_bucket(p_method text)
returns text
language sql
immutable
as $$
  select case
    when lower(trim(coalesce(p_method, ''))) = 'cash' then 'cash'
    when lower(trim(coalesce(p_method, ''))) in (
      'card',
      'creditcard',
      'credit_card',
      'atm'
    ) then 'card'
    else 'pay'
  end;
$$;

comment on function public.office_payment_bucket(text) is
  'Maps POS payment methods into the Office reporting buckets cash/card/pay.';

create or replace view public.v_office_pos_sales_events as
select
  ('payment:' || p.id::text) as event_key,
  'payments'::text as source_table,
  p.id as source_id,
  p.restaurant_id as store_id,
  r.brand_id,
  p.created_at as occurred_at,
  date(p.created_at at time zone 'Asia/Ho_Chi_Minh') as sale_date,
  public.office_payment_bucket(p.method) as payment_bucket,
  case when p.is_revenue then 'sale' else 'service' end as event_type,
  case when p.is_revenue then p.amount else 0 end::numeric(15,2) as signed_amount,
  case when p.is_revenue then p.amount else 0 end::numeric(15,2) as gross_amount,
  case when p.is_revenue then 0 else p.amount end::numeric(15,2) as service_amount,
  1::integer as transaction_count,
  p.method as raw_method,
  jsonb_build_object(
    'payment_id', p.id,
    'order_id', p.order_id,
    'amount', p.amount,
    'method', p.method,
    'is_revenue', p.is_revenue,
    'created_at', p.created_at
  ) as raw_payload
from public.payments p
join public.restaurants r on r.id = p.restaurant_id

union all

select
  ('order_cancel:' || o.id::text) as event_key,
  'orders'::text as source_table,
  o.id as source_id,
  o.restaurant_id as store_id,
  r.brand_id,
  coalesce(o.updated_at, o.created_at) as occurred_at,
  date(coalesce(o.updated_at, o.created_at) at time zone 'Asia/Ho_Chi_Minh') as sale_date,
  'pay'::text as payment_bucket,
  'cancel'::text as event_type,
  0::numeric(15,2) as signed_amount,
  0::numeric(15,2) as gross_amount,
  0::numeric(15,2) as service_amount,
  1::integer as transaction_count,
  null::text as raw_method,
  jsonb_build_object(
    'order_id', o.id,
    'status', o.status,
    'sales_channel', o.sales_channel,
    'created_at', o.created_at,
    'updated_at', o.updated_at
  ) as raw_payload
from public.orders o
join public.restaurants r on r.id = o.restaurant_id
where o.status = 'cancelled'

union all

select
  ('external_sale:' || es.id::text) as event_key,
  'external_sales'::text as source_table,
  es.id as source_id,
  es.restaurant_id as store_id,
  r.brand_id,
  coalesce(es.completed_at, es.updated_at, es.created_at) as occurred_at,
  date(coalesce(es.completed_at, es.updated_at, es.created_at) at time zone 'Asia/Ho_Chi_Minh') as sale_date,
  'pay'::text as payment_bucket,
  case
    when es.order_status in ('refunded', 'partially_refunded') then 'refund'
    when es.order_status = 'cancelled' then 'cancel'
    else 'sale'
  end as event_type,
  case
    when es.order_status = 'refunded' then -es.net_amount
    when es.order_status = 'partially_refunded' then
      -coalesce(
        case
          when nullif(trim(coalesce(es.payload ->> 'refund_amount', '')), '') ~ '^[0-9]+(\.[0-9]+)?$'
            then (es.payload ->> 'refund_amount')::numeric
          else null
        end,
        case
          when nullif(trim(coalesce(es.payload ->> 'refunded_amount', '')), '') ~ '^[0-9]+(\.[0-9]+)?$'
            then (es.payload ->> 'refunded_amount')::numeric
          else null
        end,
        0
      )
    when es.order_status = 'cancelled' then 0
    when es.is_revenue then es.net_amount
    else 0
  end::numeric(15,2) as signed_amount,
  case
    when es.order_status in ('completed', 'partially_refunded') and es.is_revenue
      then es.gross_amount
    else 0
  end::numeric(15,2) as gross_amount,
  0::numeric(15,2) as service_amount,
  1::integer as transaction_count,
  es.source_system as raw_method,
  jsonb_build_object(
    'external_sale_id', es.id,
    'external_order_id', es.external_order_id,
    'source_system', es.source_system,
    'order_status', es.order_status,
    'gross_amount', es.gross_amount,
    'net_amount', es.net_amount,
    'payload', es.payload
  ) as raw_payload
from public.external_sales es
join public.restaurants r on r.id = es.restaurant_id
where es.order_status in (
  'completed',
  'cancelled',
  'refunded',
  'partially_refunded'
);

comment on view public.v_office_pos_sales_events is
  'Read-only Office POS sales event feed. Buckets POS payment methods into cash/card/pay and exposes sale/service/cancel/refund events for immutable Office import.';

create or replace view public.v_office_pos_sales_bucket_summary as
select
  store_id,
  brand_id,
  sale_date,
  payment_bucket,
  sum(gross_amount)::numeric(15,2) as gross_sales,
  sum(service_amount)::numeric(15,2) as service_amount,
  sum(case when event_type = 'sale' then signed_amount else 0 end)::numeric(15,2) as sales_amount,
  abs(sum(case when event_type = 'refund' then signed_amount else 0 end))::numeric(15,2) as refund_amount,
  abs(sum(case when event_type = 'void' then signed_amount else 0 end))::numeric(15,2) as void_amount,
  sum(signed_amount)::numeric(15,2) as net_sales,
  count(*) filter (where event_type = 'sale')::integer as sale_count,
  count(*) filter (where event_type = 'service')::integer as service_count,
  count(*) filter (where event_type = 'cancel')::integer as cancel_count,
  count(*) filter (where event_type = 'refund')::integer as refund_count,
  count(*) filter (where event_type = 'void')::integer as void_count
from public.v_office_pos_sales_events
group by store_id, brand_id, sale_date, payment_bucket;

comment on view public.v_office_pos_sales_bucket_summary is
  'Aggregates v_office_pos_sales_events by store/date/payment_bucket for Office cash/card/pay reporting.';

grant execute on function public.office_payment_bucket(text) to authenticated;
grant select on public.v_office_pos_sales_events to authenticated;
grant select on public.v_office_pos_sales_bucket_summary to authenticated;
