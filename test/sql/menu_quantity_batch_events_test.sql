RESET ROLE;
BEGIN;
SELECT set_config('pos.quota_event_ids_v2','{}',true);
DELETE FROM pos_live_events WHERE source_table='menu_discount_quantities';
UPDATE menu_discount_quantities SET remaining=remaining WHERE remaining IS NOT NULL;
SELECT fixture_assert(NOT EXISTS(SELECT 1 FROM pos_live_events WHERE source_table='menu_discount_quantities'),
  'unchanged quota statement emits no invalidation');
UPDATE menu_discount_quantities SET remaining=8 WHERE menu_item_id='40000000-0000-0000-0000-000000000001';
UPDATE menu_discount_quantities SET remaining=7 WHERE menu_item_id='40000000-0000-0000-0000-000000000002';
SELECT fixture_assert((SELECT count(*)=1 AND max(cardinality(affected_ids))=2
  FROM pos_live_events WHERE source_table='menu_discount_quantities'),
  'two statements merge exact menu IDs into one compatible transaction event');
SELECT fixture_assert((SELECT affected_ids @> ARRAY[
  '40000000-0000-0000-0000-000000000001'::uuid,
  '40000000-0000-0000-0000-000000000002'::uuid]
  FROM pos_live_events WHERE source_table='menu_discount_quantities'),
  'signal contains both changed IDs for bounded RLS reads');
SAVEPOINT quota_abort;
UPDATE menu_discount_quantities SET remaining=6 WHERE menu_item_id='40000000-0000-0000-0000-000000000001';
ROLLBACK TO quota_abort;
SELECT fixture_assert((SELECT count(*)=1 FROM pos_live_events WHERE source_table='menu_discount_quantities'),
  'savepoint abort preserves prior event without duplication');
SELECT fixture_assert(NOT has_function_privilege('authenticated','public.emit_menu_discount_quantity_batch_v2()','EXECUTE')
  AND NOT has_function_privilege('anon','public.emit_menu_discount_quantity_batch_v2()','EXECUTE'),
  'quota trigger function cannot be called by public API roles');
ROLLBACK;
SELECT 'MENU_QUANTITY_BATCH_EVENTS=PASS';
