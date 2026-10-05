-- Read-only checks required before adding Office's POS batch readers.
do $check$
begin
  if to_regprocedure('public.office_get_inventory_nxt_snapshot(uuid,date,date)') is null
    or to_regprocedure('public.office_get_inventory_purchase_orders(uuid,uuid,text)') is null
    or to_regprocedure('public.office_get_inventory_purchase_order_detail(uuid)') is null
    or to_regprocedure('public.procurement_order_snapshot(uuid,uuid,jsonb)') is null
    or to_regprocedure('public.procurement_actor(uuid,jsonb)') is null
    or to_regclass('public.photo_objet_sales_pull_runs') is null then
    raise exception 'OFFICE_STORE_BATCH_SOURCE_CONTRACT_MISSING';
  end if;
end;
$check$;
