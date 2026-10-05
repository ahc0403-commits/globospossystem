-- Read-only production verification after the atomic migration apply.
do $verify$
begin
  if to_regprocedure('public.office_inventory_nxt_snapshots_batch(uuid[],date,date)') is null
    or to_regprocedure('public.office_photo_collection_history_batch(uuid[],date,date)') is null
    or to_regprocedure('public.office_inventory_purchase_orders_batch(uuid[],text)') is null
    or to_regprocedure('public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text)') is null then
    raise exception 'OFFICE_STORE_BATCH_FUNCTION_MISSING';
  end if;
  if has_function_privilege('anon', 'public.office_inventory_nxt_snapshots_batch(uuid[],date,date)', 'execute')
    or has_function_privilege('authenticated', 'public.office_photo_collection_history_batch(uuid[],date,date)', 'execute')
    or has_function_privilege('anon', 'public.office_inventory_purchase_orders_batch(uuid[],text)', 'execute')
    or has_function_privilege('authenticated', 'public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text)', 'execute')
    or not has_function_privilege('service_role', 'public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text)', 'execute') then
    raise exception 'OFFICE_STORE_BATCH_EXECUTE_ACL_INVALID';
  end if;
  if public.office_inventory_nxt_snapshots_batch(array[]::uuid[], current_date, current_date) <> '{"rows":[]}'::jsonb
    or public.office_photo_collection_history_batch(array[]::uuid[], current_date, current_date) <> '{"rows":[]}'::jsonb
    or public.office_inventory_purchase_orders_batch(array[]::uuid[], null) <> '{"rows":[]}'::jsonb then
    raise exception 'OFFICE_STORE_BATCH_EMPTY_SCOPE_INVALID';
  end if;
end;
$verify$;
