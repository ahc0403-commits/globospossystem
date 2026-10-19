begin;

-- POS-side contract. Apply on POS before deploying the Office bridge caller.
-- Historical Photo collection is read-only here; no schedules or collectors
-- are created or re-enabled.
create or replace function public.office_inventory_nxt_snapshots_batch(
  p_store_ids uuid[], p_period_start date, p_period_end date
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare result jsonb;
begin
  if p_store_ids is null or cardinality(p_store_ids) > 100
    or array_position(p_store_ids, null) is not null
    or p_period_start is null or p_period_end is null then
    raise exception 'INVENTORY_NXT_PERIOD_REQUIRED';
  end if;
  if p_period_end < p_period_start or p_period_end - p_period_start > 366 then
    raise exception 'INVENTORY_NXT_PERIOD_INVALID';
  end if;
  select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(snapshot)), '[]'::jsonb))
  into result from (
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
    where transaction.restaurant_id = any(p_store_ids)
    group by transaction.ingredient_id
  )
  select
    item.id as item_id,
    item.id as inventory_item_id,
    item.restaurant_id as store_id,
    product.product_code as item_code,
    item.name as item_name,
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
    item.cost_per_unit::numeric as unit_cost,
    greatest(item.updated_at, rollup.last_transaction_at) as last_source_updated_at,
    case when item.is_active then 'active' else 'inactive' end as status
  from public.inventory_items item
  left join transaction_rollup rollup
    on rollup.ingredient_id = item.id
  left join (
    select distinct on (candidate.inventory_item_id)
      candidate.inventory_item_id, candidate.product_code, candidate.category
    from public.inventory_products candidate
    join public.inventory_items scoped_item on scoped_item.id = candidate.inventory_item_id
    where scoped_item.restaurant_id = any(p_store_ids)
    order by candidate.inventory_item_id, candidate.is_active desc,
      candidate.updated_at desc, candidate.id
  ) product on product.inventory_item_id = item.id
  where item.restaurant_id = any(p_store_ids)
  order by lower(item.name), item.id
  ) snapshot;
  return result;
end;
$$;

create or replace function public.office_photo_collection_history_batch(
  p_store_ids uuid[], p_from date, p_to date
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare result jsonb;
begin
  if p_store_ids is null or cardinality(p_store_ids) > 100
    or array_position(p_store_ids, null) is not null
    or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'PHOTO_HISTORY_SCOPE_INVALID';
  end if;
  select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(latest)), '[]'::jsonb))
  into result from (
    select distinct on (store_id)
      store_id,target_date,status,rows_read,aggregate_rows,started_at,finished_at,
      slot_date_hcm,slot_time_hcm,interval_start_at,interval_end_at
    from public.photo_objet_sales_pull_runs
    where store_id = any(p_store_ids) and target_date between p_from and p_to
    order by store_id, started_at desc, id desc
  ) latest;
  return result;
end;
$$;
revoke all on function public.office_inventory_nxt_snapshots_batch(uuid[],date,date) from public,anon,authenticated;
revoke all on function public.office_photo_collection_history_batch(uuid[],date,date) from public,anon,authenticated;
grant execute on function public.office_inventory_nxt_snapshots_batch(uuid[],date,date) to service_role;
grant execute on function public.office_photo_collection_history_batch(uuid[],date,date) to service_role;

-- Set-based version of office_get_inventory_purchase_orders for the authorized
-- POS store IDs supplied by the Office bridge. The source columns and store
-- authorization predicate match the existing single-store RPC.
create or replace function public.office_inventory_purchase_orders_batch(
  p_store_ids uuid[], p_status text default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if p_store_ids is null or cardinality(p_store_ids) > 100
    or array_position(p_store_ids, null) is not null then
    raise exception 'PURCHASE_BATCH_SCOPE_INVALID';
  end if;
  select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(orders) - 'scope_order'
    order by orders.scope_order, orders.created_at desc, orders.purchase_order_no desc), '[]'::jsonb))
  into result from (
    select po.id, po.purchase_order_no, po.restaurant_id, po.brand_id,
      po.supplier_id, supplier.supplier_name, po.status,
      po.requested_delivery_date, po.total_supply_amount, po.tax_amount,
      po.total_amount, po.office_reviewed_at, po.created_at, po.updated_at,
      array_position(p_store_ids, po.restaurant_id) as scope_order
    from public.inventory_purchase_orders po
    join public.inventory_suppliers supplier on supplier.id = po.supplier_id
    where po.restaurant_id = any(p_store_ids)
      and public.can_access_inventory_purchase_store(po.restaurant_id)
      and (p_status is null or po.status = p_status)
  ) orders;
  return result;
end;
$$;
revoke all on function public.office_inventory_purchase_orders_batch(uuid[],text)
  from public, anon, authenticated;
grant execute on function public.office_inventory_purchase_orders_batch(uuid[],text)
  to service_role;

-- Prepare auto-handoff evidence in one scoped, set-based read. Accounting
-- writes remain serial in Office, but neither POS details nor the procurement
-- snapshot are fetched once per order over the network.
create function public.office_inventory_purchase_handoff_batch(
  p_store_ids uuid[], p_order_ids uuid[], p_subject_id text
) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare scoped_store uuid;
begin
  if auth.role() is distinct from 'service_role'
    or p_store_ids is null or cardinality(p_store_ids) not between 1 and 100
    or p_order_ids is null or cardinality(p_order_ids) not between 1 and 50
    or array_position(p_store_ids, null) is not null
    or array_position(p_order_ids, null) is not null
    or nullif(btrim(p_subject_id), '') is null then
    raise exception 'PURCHASE_HANDOFF_SCOPE_INVALID';
  end if;
  if (select count(distinct id) from public.inventory_purchase_orders
      where id = any(p_order_ids) and restaurant_id = any(p_store_ids)
        and public.can_access_inventory_purchase_store(restaurant_id))
       <> (select count(distinct requested) from unnest(p_order_ids) requested) then
    raise exception 'PURCHASE_HANDOFF_SCOPE_FORBIDDEN';
  end if;
  for scoped_store in select distinct po.restaurant_id
    from public.inventory_purchase_orders po where po.id = any(p_order_ids)
  loop
    perform public.procurement_actor(scoped_store, jsonb_build_object(
      'system', 'office', 'subject_id', p_subject_id,
      'store_id', scoped_store, 'can_view_prices', true));
  end loop;

  return (with orders as materialized (
    select po.* from public.inventory_purchase_orders po
    where po.id = any(p_order_ids) and po.restaurant_id = any(p_store_ids)
  ), detail_lines as (
    select l.purchase_order_id,
      jsonb_agg(jsonb_build_object(
        'id', l.id, 'product_id', l.product_id,
        'product_name', p.name, 'supplier_item_id', l.supplier_item_id,
        'recommended_quantity_base', l.recommended_quantity_base,
        'ordered_quantity_base', l.ordered_quantity_base,
        'ordered_quantity_unit', l.ordered_quantity_unit,
        'order_unit', l.order_unit, 'unit_price', l.unit_price,
        'supply_amount', l.supply_amount, 'tax_amount', l.tax_amount,
        'memo', l.memo, 'recommendation_snapshot', l.recommendation_snapshot,
        'created_at', l.created_at, 'updated_at', l.updated_at
      ) order by l.created_at) rows
    from public.inventory_purchase_order_lines l
    join orders po on po.id = l.purchase_order_id
    join public.inventory_products p on p.id = l.product_id
    group by l.purchase_order_id
  ), snapshot_lines as (
    select l.purchase_order_id,
      jsonb_agg(to_jsonb(l) || jsonb_build_object('product_name', p.name)
        order by l.id) rows
    from public.inventory_purchase_order_lines l
    join orders po on po.id = l.purchase_order_id
    join public.inventory_products p on p.id = l.product_id
    group by l.purchase_order_id
  ), all_receipts as materialized (
    select r.* from public.inventory_receipts r
    join orders po on po.id = r.purchase_order_id
    where r.status <> 'cancelled'
  ), flat_receipts as (
    select r.purchase_order_id,
      jsonb_agg(jsonb_build_object(
        'id', r.id, 'purchase_order_id', r.purchase_order_id,
        'restaurant_id', r.restaurant_id, 'status', r.status,
        'submitted_at', r.submitted_at, 'received_at', r.received_at,
        'received_by', r.received_by, 'statement_number', r.statement_number,
        'statement_date', r.statement_date,
        'total_supply_amount', r.total_supply_amount,
        'tax_amount', r.tax_amount, 'total_amount', r.total_amount,
        'verified_by', r.verified_by, 'verified_at', r.verified_at,
        'verification_reason', r.verification_reason, 'memo', r.memo,
        'created_at', r.created_at, 'updated_at', r.updated_at
      ) order by r.received_at desc, r.created_at desc, r.id desc) rows
    from all_receipts r group by r.purchase_order_id
  ), flat_receipt_lines as (
    select r.purchase_order_id,
      jsonb_agg(jsonb_build_object(
        'id', l.id, 'receipt_id', l.receipt_id,
        'purchase_order_line_id', l.purchase_order_line_id,
        'product_id', l.product_id,
        'received_quantity_base', l.received_quantity_base,
        'accepted_quantity_base', l.accepted_quantity_base,
        'rejected_quantity_base', l.rejected_quantity_base,
        'actual_unit_price', l.actual_unit_price,
        'final_supply_amount', l.final_supply_amount,
        'final_tax_amount', l.final_tax_amount,
        'discrepancy_reason', l.discrepancy_reason, 'memo', l.memo,
        'created_at', l.created_at, 'updated_at', l.updated_at
      ) order by l.created_at, l.id) rows
    from public.inventory_receipt_lines l
    join all_receipts r on r.id = l.receipt_id
    group by r.purchase_order_id
  ), returns as materialized (
    select ret.* from public.inventory_supplier_returns ret
    join orders po on po.id = ret.purchase_order_id
  ), returned as (
    select receipt_line_id, sum(quantity_base) qty
    from returns group by receipt_line_id
  ), snapshot_receipt_lines as (
    select l.receipt_id,
      jsonb_agg(to_jsonb(l) || jsonb_build_object(
        'returned_quantity_base', coalesce(ret.qty, 0)) order by l.id) rows
    from public.inventory_receipt_lines l
    join all_receipts r on r.id = l.receipt_id and r.status = 'confirmed'
    left join returned ret on ret.receipt_line_id = l.id
    group by l.receipt_id
  ), snapshot_receipts as (
    select r.purchase_order_id,
      jsonb_agg(to_jsonb(r) || jsonb_build_object('lines', l.rows)
        order by r.id) rows
    from all_receipts r
    left join snapshot_receipt_lines l on l.receipt_id = r.id
    where r.status = 'confirmed'
    group by r.purchase_order_id
  ), snapshot_returns as (
    select purchase_order_id, jsonb_agg(to_jsonb(ret) order by ret.id) rows
    from returns ret group by purchase_order_id
  )
  select jsonb_build_object('rows', coalesce(jsonb_agg(jsonb_build_object(
    'order_id', po.id, 'restaurant_id', po.restaurant_id,
    'detail', jsonb_build_object(
      'order', to_jsonb(po) || jsonb_build_object('supplier_name', supplier.supplier_name),
      'lines', coalesce(dl.rows, '[]'::jsonb)),
    'receipts', coalesce(fr.rows, '[]'::jsonb),
    'receipt_lines', coalesce(fl.rows, '[]'::jsonb),
    'snapshot', jsonb_build_object(
      'contract_version', 2, 'order', to_jsonb(po),
      'lines', coalesce(sl.rows, '[]'::jsonb),
      'receipts', coalesce(sr.rows, '[]'::jsonb),
      'returns', coalesce(rt.rows, '[]'::jsonb))
  ) order by array_position(p_order_ids, po.id)), '[]'::jsonb))
  from orders po
  left join public.inventory_suppliers supplier on supplier.id = po.supplier_id
  left join detail_lines dl on dl.purchase_order_id = po.id
  left join snapshot_lines sl on sl.purchase_order_id = po.id
  left join flat_receipts fr on fr.purchase_order_id = po.id
  left join flat_receipt_lines fl on fl.purchase_order_id = po.id
  left join snapshot_receipts sr on sr.purchase_order_id = po.id
  left join snapshot_returns rt on rt.purchase_order_id = po.id);
end;
$$;
revoke all on function public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text)
  from public, anon, authenticated;
grant execute on function public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text)
  to service_role;
notify pgrst, 'reload schema';
commit;
