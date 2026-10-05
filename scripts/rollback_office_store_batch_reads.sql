-- Use only for an explicitly authorized rollback after disabling Office callers.
begin;
drop function if exists public.office_inventory_purchase_handoff_batch(uuid[],uuid[],text);
drop function if exists public.office_inventory_purchase_orders_batch(uuid[],text);
drop function if exists public.office_photo_collection_history_batch(uuid[],date,date);
drop function if exists public.office_inventory_nxt_snapshots_batch(uuid[],date,date);
notify pgrst, 'reload schema';
commit;
