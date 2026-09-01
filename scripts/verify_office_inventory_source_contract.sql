do $verify$
declare
  event_columns text[];
  expected_columns constant text[] := array[
    'source_event_id', 'store_id', 'event_type', 'event_date', 'item_id',
    'item_code', 'item_name', 'category', 'unit', 'quantity_in',
    'quantity_out', 'system_quantity', 'counted_quantity',
    'variance_quantity', 'unit_cost', 'reference_type', 'reference_id',
    'evidence_count', 'status', 'occurred_at', 'updated_at'
  ];
  unauthorized_view_grants integer;
  unauthorized_function_grants integer;
  invalid_snapshot_rows integer;
begin
  if to_regclass('public.v_office_inventory_source_events') is null then
    raise exception 'OFFICE_INVENTORY_VERIFY_VIEW_MISSING';
  end if;
  if to_regprocedure(
    'public.office_get_inventory_nxt_snapshot(uuid,date,date)'
  ) is null then
    raise exception 'OFFICE_INVENTORY_VERIFY_RPC_MISSING';
  end if;

  select array_agg(column_name order by ordinal_position)
  into event_columns
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'v_office_inventory_source_events';
  if event_columns is distinct from expected_columns then
    raise exception 'OFFICE_INVENTORY_VERIFY_COLUMNS: %', event_columns;
  end if;

  if not exists (
    select 1
    from pg_class view_class
    join pg_namespace namespace
      on namespace.oid = view_class.relnamespace
    where namespace.nspname = 'public'
      and view_class.relname = 'v_office_inventory_source_events'
      and coalesce(view_class.reloptions, array[]::text[])
        @> array['security_invoker=true']
  ) then
    raise exception 'OFFICE_INVENTORY_VERIFY_VIEW_NOT_SECURITY_INVOKER';
  end if;

  select count(*)
  into unauthorized_view_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'v_office_inventory_source_events'
    and privilege_type = 'SELECT'
    and grantee in ('PUBLIC', 'anon', 'authenticated');
  if unauthorized_view_grants <> 0
     or not has_table_privilege(
       'service_role',
       'public.v_office_inventory_source_events',
       'SELECT'
     ) then
    raise exception 'OFFICE_INVENTORY_VERIFY_VIEW_GRANTS';
  end if;

  select count(*)
  into unauthorized_function_grants
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name = 'office_get_inventory_nxt_snapshot'
    and privilege_type = 'EXECUTE'
    and grantee in ('PUBLIC', 'anon', 'authenticated');
  if unauthorized_function_grants <> 0
     or not has_function_privilege(
       'service_role',
       'public.office_get_inventory_nxt_snapshot(uuid,date,date)',
       'EXECUTE'
     ) then
    raise exception 'OFFICE_INVENTORY_VERIFY_RPC_GRANTS';
  end if;

  select count(*)
  into invalid_snapshot_rows
  from public.restaurants restaurant
  cross join lateral public.office_get_inventory_nxt_snapshot(
    restaurant.id,
    current_date - 30,
    current_date
  ) snapshot
  where abs(
    snapshot.opening_quantity
    + snapshot.receipt_quantity
    - snapshot.issue_quantity
    - snapshot.closing_quantity
  ) > 0.000001;
  if invalid_snapshot_rows <> 0 then
    raise exception 'OFFICE_INVENTORY_VERIFY_NXT_BALANCE: %',
      invalid_snapshot_rows;
  end if;
end;
$verify$;

select 'office inventory source contract verification passed' as result;
