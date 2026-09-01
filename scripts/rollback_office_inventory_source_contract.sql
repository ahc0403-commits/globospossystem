revoke all on function public.office_get_inventory_nxt_snapshot(uuid, date, date)
  from public, anon, authenticated, service_role;
drop function if exists
  public.office_get_inventory_nxt_snapshot(uuid, date, date);

revoke all on public.v_office_inventory_source_events
  from public, anon, authenticated, service_role;
drop view if exists public.v_office_inventory_source_events;

drop index if exists public.inventory_transactions_store_created_at_idx;
