-- Restaurant/POS inventory source contract consumed by the Office pos-bridge.
-- The contract is read-only and is exposed only to the service_role.

create index if not exists inventory_transactions_store_created_at_idx
  on public.inventory_transactions (restaurant_id, created_at, ingredient_id);

create or replace view public.v_office_inventory_source_events
with (security_invoker = true) as
with purchase_order_events as (
  select
    purchase.id as source_event_id,
    purchase.restaurant_id as store_id,
    'purchase_order'::text as event_type,
    (coalesce(
      purchase.ordered_at,
      purchase.submitted_at,
      purchase.created_at
    ) at time zone 'Asia/Ho_Chi_Minh')::date as event_date,
    null::uuid as item_id,
    purchase.purchase_order_no as item_code,
    concat('Purchase order ', purchase.purchase_order_no) as item_name,
    'purchase_order'::text as category,
    'order'::text as unit,
    0::numeric as quantity_in,
    0::numeric as quantity_out,
    null::numeric as system_quantity,
    null::numeric as counted_quantity,
    null::numeric as variance_quantity,
    purchase.total_amount as unit_cost,
    'inventory_purchase_order'::text as reference_type,
    purchase.id as reference_id,
    1 + count(document.id)::integer as evidence_count,
    purchase.status,
    coalesce(
      purchase.ordered_at,
      purchase.submitted_at,
      purchase.created_at
    ) as occurred_at,
    greatest(
      purchase.updated_at,
      max(document.updated_at),
      max(document.generated_at)
    ) as updated_at
  from public.inventory_purchase_orders purchase
  left join public.inventory_purchase_documents document
    on document.purchase_order_id = purchase.id
  group by purchase.id
),
receipt_events as (
  select
    purchase.id as source_event_id,
    purchase.restaurant_id as store_id,
    'receipt'::text as event_type,
    (max(receipt.received_at) at time zone 'Asia/Ho_Chi_Minh')::date
      as event_date,
    null::uuid as item_id,
    purchase.purchase_order_no as item_code,
    concat('Receipt for ', purchase.purchase_order_no) as item_name,
    'receipt'::text as category,
    'base'::text as unit,
    coalesce(sum(line.accepted_quantity_base), 0)::numeric as quantity_in,
    0::numeric as quantity_out,
    null::numeric as system_quantity,
    null::numeric as counted_quantity,
    null::numeric as variance_quantity,
    coalesce(sum(line.final_supply_amount), 0)::numeric as unit_cost,
    'inventory_purchase_order'::text as reference_type,
    purchase.id as reference_id,
    count(distinct receipt.id)::integer
      + count(distinct receipt.statement_storage_path) filter (
          where receipt.statement_storage_path is not null
        )::integer as evidence_count,
    case
      when bool_and(receipt.status = 'confirmed') then 'confirmed'
      else 'in_progress'
    end as status,
    max(receipt.received_at) as occurred_at,
    max(greatest(receipt.updated_at, line.updated_at)) as updated_at
  from public.inventory_purchase_orders purchase
  join public.inventory_receipts receipt
    on receipt.purchase_order_id = purchase.id
   and receipt.status <> 'cancelled'
  join public.inventory_receipt_lines line
    on line.receipt_id = receipt.id
  group by purchase.id
),
transaction_events as (
  select
    transaction.id as source_event_id,
    transaction.restaurant_id as store_id,
    case transaction.transaction_type
      when 'restock' then 'receipt'
      when 'deduct' then 'issue'
      when 'waste' then 'issue'
      else 'adjustment'
    end::text as event_type,
    coalesce(
      transaction.effective_date,
      (transaction.created_at at time zone 'Asia/Ho_Chi_Minh')::date
    ) as event_date,
    item.id as item_id,
    product.product_code as item_code,
    item.name as item_name,
    product.category,
    item.unit,
    greatest(transaction.quantity_g, 0)::numeric as quantity_in,
    abs(least(transaction.quantity_g, 0))::numeric as quantity_out,
    transaction.stock_before::numeric as system_quantity,
    transaction.stock_after::numeric as counted_quantity,
    transaction.quantity_g::numeric as variance_quantity,
    item.cost_per_unit::numeric as unit_cost,
    coalesce(transaction.reference_type, 'inventory_transaction')
      as reference_type,
    coalesce(transaction.reference_id, transaction.id) as reference_id,
    1::integer as evidence_count,
    transaction.transaction_type as status,
    transaction.created_at as occurred_at,
    transaction.created_at as updated_at
  from public.inventory_transactions transaction
  join public.inventory_items item
    on item.id = transaction.ingredient_id
   and item.restaurant_id = transaction.restaurant_id
  left join lateral (
    select candidate.product_code, candidate.category
    from public.inventory_products candidate
    where candidate.inventory_item_id = item.id
    order by candidate.is_active desc, candidate.updated_at desc, candidate.id
    limit 1
  ) product on true
  where coalesce(transaction.reference_type, '') <> 'physical_count'
),
physical_count_events as (
  select
    physical_count.id as source_event_id,
    physical_count.restaurant_id as store_id,
    'stock_count'::text as event_type,
    physical_count.count_date as event_date,
    item.id as item_id,
    product.product_code as item_code,
    item.name as item_name,
    product.category,
    item.unit,
    0::numeric as quantity_in,
    0::numeric as quantity_out,
    physical_count.theoretical_quantity_g::numeric as system_quantity,
    physical_count.actual_quantity_g::numeric as counted_quantity,
    physical_count.variance_g::numeric as variance_quantity,
    item.cost_per_unit::numeric as unit_cost,
    'inventory_physical_count'::text as reference_type,
    physical_count.id as reference_id,
    1::integer as evidence_count,
    'completed'::text as status,
    coalesce(physical_count.updated_at, physical_count.created_at)
      as occurred_at,
    coalesce(physical_count.updated_at, physical_count.created_at)
      as updated_at
  from public.inventory_physical_counts physical_count
  join public.inventory_items item
    on item.id = physical_count.ingredient_id
   and item.restaurant_id = physical_count.restaurant_id
  left join lateral (
    select candidate.product_code, candidate.category
    from public.inventory_products candidate
    where candidate.inventory_item_id = item.id
    order by candidate.is_active desc, candidate.updated_at desc, candidate.id
    limit 1
  ) product on true
),
stock_audit_events as (
  select
    line.id as source_event_id,
    session.restaurant_id as store_id,
    'stock_count'::text as event_type,
    coalesce(
      session.completed_at::date,
      session.planned_date,
      (session.updated_at at time zone 'Asia/Ho_Chi_Minh')::date
    ) as event_date,
    coalesce(product.inventory_item_id, product.id) as item_id,
    product.product_code as item_code,
    product.name as item_name,
    product.category,
    product.base_unit as unit,
    0::numeric as quantity_in,
    0::numeric as quantity_out,
    line.theoretical_quantity_base::numeric as system_quantity,
    line.actual_quantity_base::numeric as counted_quantity,
    line.variance_quantity_base::numeric as variance_quantity,
    null::numeric as unit_cost,
    'inventory_stock_audit'::text as reference_type,
    session.id as reference_id,
    (1 + case when line.photo_url is null then 0 else 1 end)::integer
      as evidence_count,
    line.status,
    coalesce(session.completed_at, session.started_at, session.created_at)
      as occurred_at,
    greatest(line.updated_at, session.updated_at) as updated_at
  from public.inventory_stock_audit_sessions session
  join public.inventory_stock_audit_lines line
    on line.session_id = session.id
  join public.inventory_products product
    on product.id = line.product_id
  where session.status = 'completed'
    and line.status = 'counted'
)
select * from purchase_order_events
union all
select * from receipt_events
union all
select * from transaction_events
union all
select * from physical_count_events
union all
select * from stock_audit_events;

revoke all on public.v_office_inventory_source_events
  from public, anon, authenticated;
grant select on public.v_office_inventory_source_events to service_role;

create or replace function public.office_get_inventory_nxt_snapshot(
  p_store_id uuid,
  p_period_start date,
  p_period_end date
) returns table (
  item_id uuid,
  inventory_item_id uuid,
  store_id uuid,
  item_code text,
  item_name text,
  category text,
  unit text,
  opening_quantity numeric,
  receipt_quantity numeric,
  issue_quantity numeric,
  closing_quantity numeric,
  unit_cost numeric,
  last_source_updated_at timestamptz,
  status text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_store_id is null or p_period_start is null or p_period_end is null then
    raise exception 'INVENTORY_NXT_PERIOD_REQUIRED';
  end if;
  if p_period_end < p_period_start
     or p_period_end - p_period_start > 366 then
    raise exception 'INVENTORY_NXT_PERIOD_INVALID';
  end if;

  return query
  with transaction_rollup as (
    select
      transaction.ingredient_id,
      coalesce(sum(transaction.quantity_g) filter (
        where coalesce(
          transaction.effective_date,
          (transaction.created_at at time zone 'Asia/Ho_Chi_Minh')::date
        ) between p_period_start and p_period_end
      ), 0)::numeric as period_net,
      coalesce(sum(greatest(transaction.quantity_g, 0)) filter (
        where coalesce(
          transaction.effective_date,
          (transaction.created_at at time zone 'Asia/Ho_Chi_Minh')::date
        ) between p_period_start and p_period_end
      ), 0)::numeric as receipts,
      coalesce(sum(abs(least(transaction.quantity_g, 0))) filter (
        where coalesce(
          transaction.effective_date,
          (transaction.created_at at time zone 'Asia/Ho_Chi_Minh')::date
        ) between p_period_start and p_period_end
      ), 0)::numeric as issues,
      coalesce(sum(transaction.quantity_g) filter (
        where coalesce(
          transaction.effective_date,
          (transaction.created_at at time zone 'Asia/Ho_Chi_Minh')::date
        ) > p_period_end
      ), 0)::numeric as future_net,
      max(transaction.created_at) as last_transaction_at
    from public.inventory_transactions transaction
    where transaction.restaurant_id = p_store_id
    group by transaction.ingredient_id
  )
  select
    item.id,
    item.id,
    item.restaurant_id,
    product.product_code,
    item.name,
    product.category,
    item.unit,
    (
      item.current_stock
      - coalesce(rollup.future_net, 0)
      - coalesce(rollup.period_net, 0)
    )::numeric as opening_quantity,
    coalesce(rollup.receipts, 0)::numeric as receipt_quantity,
    coalesce(rollup.issues, 0)::numeric as issue_quantity,
    (item.current_stock - coalesce(rollup.future_net, 0))::numeric
      as closing_quantity,
    item.cost_per_unit::numeric,
    greatest(item.updated_at, rollup.last_transaction_at),
    case when item.is_active then 'active' else 'inactive' end
  from public.inventory_items item
  left join transaction_rollup rollup
    on rollup.ingredient_id = item.id
  left join lateral (
    select candidate.product_code, candidate.category
    from public.inventory_products candidate
    where candidate.inventory_item_id = item.id
    order by candidate.is_active desc, candidate.updated_at desc, candidate.id
    limit 1
  ) product on true
  where item.restaurant_id = p_store_id
  order by lower(item.name), item.id;
end;
$$;

revoke all on function public.office_get_inventory_nxt_snapshot(uuid, date, date)
  from public, anon, authenticated;
grant execute on function
  public.office_get_inventory_nxt_snapshot(uuid, date, date)
  to service_role;

comment on view public.v_office_inventory_source_events is
  'Read-only Restaurant inventory source events consumed by the Office pos-bridge.';
comment on function public.office_get_inventory_nxt_snapshot(uuid, date, date) is
  'Read-only per-store opening, receipt, issue and closing inventory snapshot for Office accounting.';
