-- 20260604001000_pos_payment_refund_void_adjustments.sql
--
-- Append-only post-payment refund/void ledger for POS payments.
--
-- Existing payments remain a positive-only payment ledger. Refund/void facts are
-- recorded in payment_adjustments and exposed to Office through the existing
-- v_office_pos_sales_events / v_office_pos_sales_bucket_summary read contract.

begin;

create table if not exists public.payment_adjustments (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id),
  order_id uuid not null references public.orders(id),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  adjustment_type text not null,
  amount numeric(12,2) not null,
  method text not null,
  reason text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint payment_adjustments_type_check
    check (adjustment_type in ('refund', 'void')),
  constraint payment_adjustments_amount_positive
    check (amount > 0),
  constraint payment_adjustments_method_check
    check (method in (
      'CASH',
      'CREDITCARD',
      'ATM',
      'MOMO',
      'ZALOPAY',
      'VNPAY',
      'SHOPEEPAY',
      'BANKTRANSFER',
      'VOUCHER',
      'CREDITSALE',
      'OTHER'
    )),
  constraint payment_adjustments_reason_not_blank
    check (length(btrim(reason)) > 0)
);

comment on table public.payment_adjustments is
  'Append-only POS payment refund/void ledger. Existing payments are not mutated.';
comment on column public.payment_adjustments.adjustment_type is
  'refund = partial/full refund. void = full reversal before any refund exists.';
comment on column public.payment_adjustments.metadata is
  'Audit context captured at insertion time, including payment amount and WeTax follow-up signal.';

create index if not exists idx_payment_adjustments_payment_id_created_at
  on public.payment_adjustments(payment_id, created_at);

create index if not exists idx_payment_adjustments_restaurant_created_at
  on public.payment_adjustments(restaurant_id, created_at);

create or replace function public.prevent_payment_adjustments_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'PAYMENT_ADJUSTMENTS_IMMUTABLE';
end;
$$;

drop trigger if exists prevent_payment_adjustments_update_delete
  on public.payment_adjustments;

create trigger prevent_payment_adjustments_update_delete
before update or delete on public.payment_adjustments
for each row execute function public.prevent_payment_adjustments_mutation();

create or replace function public.record_payment_adjustment(
  p_payment_id uuid,
  p_adjustment_type text,
  p_amount numeric default null,
  p_reason text default null
)
returns public.payment_adjustments
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_actor public.users%rowtype;
  v_payment public.payments%rowtype;
  v_adjustment public.payment_adjustments%rowtype;
  v_adjustment_type text := lower(btrim(coalesce(p_adjustment_type, '')));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_existing_adjusted numeric(12,2);
  v_existing_void_count integer;
  v_adjustment_amount numeric(12,2);
  v_wetax_action_required boolean := false;
begin
  select *
  into v_actor
  from public.users
  where auth_id = auth.uid()
    and is_active = true
  limit 1;

  if not found or v_actor.role not in (
    'cashier',
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin'
  ) then
    raise exception 'PAYMENT_ADJUSTMENT_FORBIDDEN';
  end if;

  if v_adjustment_type not in ('refund', 'void') then
    raise exception 'PAYMENT_ADJUSTMENT_TYPE_INVALID';
  end if;

  if v_reason = '' then
    raise exception 'PAYMENT_ADJUSTMENT_REASON_REQUIRED';
  end if;

  select *
  into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND';
  end if;

  if not public.is_super_admin()
     and not exists (
       select 1
       from public.user_accessible_stores(auth.uid()) s(store_id)
       where s.store_id = v_payment.restaurant_id
     ) then
    raise exception 'PAYMENT_ADJUSTMENT_FORBIDDEN';
  end if;

  if v_payment.is_revenue is not true then
    raise exception 'PAYMENT_ADJUSTMENT_SERVICE_NOT_ALLOWED';
  end if;

  select
    coalesce(sum(amount), 0)::numeric(12,2),
    count(*) filter (where adjustment_type = 'void')::integer
  into v_existing_adjusted, v_existing_void_count
  from public.payment_adjustments
  where payment_id = p_payment_id;

  if v_existing_void_count > 0 then
    raise exception 'PAYMENT_ADJUSTMENT_ALREADY_VOIDED';
  end if;

  if v_existing_adjusted >= v_payment.amount then
    raise exception 'PAYMENT_ADJUSTMENT_ALREADY_FULLY_REVERSED';
  end if;

  if v_adjustment_type = 'void' then
    if v_existing_adjusted > 0 then
      raise exception 'PAYMENT_VOID_AFTER_REFUND_NOT_ALLOWED';
    end if;

    v_adjustment_amount := coalesce(p_amount, v_payment.amount)::numeric(12,2);

    if v_adjustment_amount <> v_payment.amount then
      raise exception 'PAYMENT_VOID_AMOUNT_MUST_MATCH_PAYMENT';
    end if;
  else
    if p_amount is null or p_amount <= 0 then
      raise exception 'PAYMENT_REFUND_AMOUNT_INVALID';
    end if;

    v_adjustment_amount := p_amount::numeric(12,2);

    if v_existing_adjusted + v_adjustment_amount > v_payment.amount then
      raise exception 'PAYMENT_REFUND_EXCEEDS_REMAINING_AMOUNT';
    end if;
  end if;

  select exists (
    select 1
    from public.einvoice_jobs ej
    where ej.order_id = v_payment.order_id
      and (
        ej.status not in ('cancelled', 'failed_terminal')
        or ej.lookup_url is not null
        or ej.redinvoice_requested = true
      )
  )
  into v_wetax_action_required;

  insert into public.payment_adjustments (
    payment_id,
    order_id,
    restaurant_id,
    adjustment_type,
    amount,
    method,
    reason,
    created_by,
    metadata
  )
  values (
    v_payment.id,
    v_payment.order_id,
    v_payment.restaurant_id,
    v_adjustment_type,
    v_adjustment_amount,
    v_payment.method,
    v_reason,
    auth.uid(),
    jsonb_build_object(
      'payment_amount', v_payment.amount,
      'previous_adjusted_amount', v_existing_adjusted,
      'remaining_amount_before', v_payment.amount - v_existing_adjusted,
      'wetax_action_required', v_wetax_action_required
    )
  )
  returning * into v_adjustment;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    case
      when v_adjustment_type = 'void' then 'void_payment'
      else 'refund_payment'
    end,
    'payment_adjustments',
    v_adjustment.id,
    jsonb_build_object(
      'payment_id', v_payment.id,
      'order_id', v_payment.order_id,
      'restaurant_id', v_payment.restaurant_id,
      'adjustment_type', v_adjustment_type,
      'amount', v_adjustment_amount,
      'method', v_payment.method,
      'wetax_action_required', v_wetax_action_required
    )
  );

  return v_adjustment;
end;
$$;

comment on function public.record_payment_adjustment(uuid, text, numeric, text) is
  'Records an append-only refund/void adjustment for a positive POS payment. Does not mutate payments/orders or perform WeTax cancellation.';

grant execute on function public.record_payment_adjustment(uuid, text, numeric, text)
  to authenticated;

alter table public.payment_adjustments enable row level security;

drop policy if exists payment_adjustments_read_scope
  on public.payment_adjustments;

create policy payment_adjustments_read_scope
  on public.payment_adjustments
  for select
  using (
    public.is_super_admin()
    or exists (
      select 1
      from public.user_accessible_stores(auth.uid()) s(store_id)
      where s.store_id = payment_adjustments.restaurant_id
    )
  );

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
  ('payment_adjustment:' || pa.id::text) as event_key,
  'payment_adjustments'::text as source_table,
  pa.id as source_id,
  pa.restaurant_id as store_id,
  r.brand_id,
  pa.created_at as occurred_at,
  date(pa.created_at at time zone 'Asia/Ho_Chi_Minh') as sale_date,
  public.office_payment_bucket(pa.method) as payment_bucket,
  pa.adjustment_type as event_type,
  (-pa.amount)::numeric(15,2) as signed_amount,
  0::numeric(15,2) as gross_amount,
  0::numeric(15,2) as service_amount,
  1::integer as transaction_count,
  pa.method as raw_method,
  jsonb_build_object(
    'payment_adjustment_id', pa.id,
    'payment_id', pa.payment_id,
    'order_id', pa.order_id,
    'adjustment_type', pa.adjustment_type,
    'amount', pa.amount,
    'method', pa.method,
    'reason', pa.reason,
    'created_at', pa.created_at,
    'metadata', pa.metadata
  ) as raw_payload
from public.payment_adjustments pa
join public.restaurants r on r.id = pa.restaurant_id

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
  'Read-only Office POS sales event feed. Buckets POS payment methods into cash/card/pay and exposes sale/service/cancel/refund/void events for immutable Office import.';

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
  'Aggregates v_office_pos_sales_events by store/date/payment_bucket for Office cash/card/pay reporting, including append-only payment refunds/voids.';

grant select on public.payment_adjustments to authenticated;
grant select on public.v_office_pos_sales_events to authenticated;
grant select on public.v_office_pos_sales_bucket_summary to authenticated;

commit;
