do $preflight$
declare
  missing_objects text[];
begin
  select array_agg(required_object order by required_object)
  into missing_objects
  from unnest(array[
    'inventory_items',
    'inventory_physical_counts',
    'inventory_products',
    'inventory_purchase_documents',
    'inventory_purchase_orders',
    'inventory_receipt_lines',
    'inventory_receipts',
    'inventory_stock_audit_lines',
    'inventory_stock_audit_sessions',
    'inventory_transactions'
  ]) required_object
  where to_regclass('public.' || required_object) is null;

  if missing_objects is not null then
    raise exception 'OFFICE_INVENTORY_PREFLIGHT_MISSING_OBJECTS: %',
      missing_objects;
  end if;

  if to_regclass('public.v_office_inventory_source_events') is not null then
    raise exception 'OFFICE_INVENTORY_PREFLIGHT_ALREADY_APPLIED';
  end if;

  if to_regprocedure(
    'public.office_get_inventory_nxt_snapshot(uuid,date,date)'
  ) is not null then
    raise exception 'OFFICE_INVENTORY_PREFLIGHT_ALREADY_APPLIED';
  end if;
end;
$preflight$;

select 'office inventory source contract preflight passed' as result;
