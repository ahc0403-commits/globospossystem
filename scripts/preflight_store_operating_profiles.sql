-- Read-only evidence for the additive operating-profile migration.
-- Counts include internal sellable projections; they are not customer menu counts.
BEGIN READ ONLY;
WITH scope AS MATERIALIZED (
  SELECT id, name FROM public.restaurants
  WHERE id IN ('273b057e-3b69-46e3-93c1-6194c2802849',
               '8bc9eef5-dcd5-46b1-b931-23f77132322c')
), table_counts AS (
  SELECT t.restaurant_id, count(*) AS count FROM public.tables t
  JOIN scope s ON s.id=t.restaurant_id GROUP BY t.restaurant_id
), menu_counts AS (
  SELECT m.restaurant_id, count(*) AS count FROM public.menu_items m
  JOIN scope s ON s.id=m.restaurant_id WHERE NOT m.is_archived GROUP BY m.restaurant_id
), assignments AS (
  SELECT a.restaurant_id, a.station_type, a.floor_label, count(*) AS count,
    count(*) FILTER (WHERE u.id IS NULL OR u.is_active IS DISTINCT FROM true
      OR u.restaurant_id IS DISTINCT FROM a.restaurant_id) AS conflicting_accounts
  FROM public.emergency_station_assignments a JOIN scope s ON s.id=a.restaurant_id
  LEFT JOIN public.users u ON u.id=a.user_id
  WHERE a.is_active GROUP BY a.restaurant_id,a.station_type,a.floor_label
), station_counts AS (
  SELECT restaurant_id,jsonb_agg(jsonb_build_object('kind',station_type,
    'stored_floor',floor_label,'accounts',count,'conflicting_accounts',conflicting_accounts)
    ORDER BY station_type,floor_label) AS stations
  FROM assignments GROUP BY restaurant_id
)
SELECT jsonb_build_object('restaurant_id',s.id,'name',s.name,
  'workflow',rs.kds_workflow,'fulfillment_mode',rs.fulfillment_mode,
  'table_count',coalesce(t.count,0),'non_archived_sellable_count',coalesce(m.count,0),
  'stations',coalesce(a.stations,'[]'::jsonb)) AS store_baseline
FROM scope s LEFT JOIN public.restaurant_settings rs ON rs.restaurant_id=s.id
LEFT JOIN table_counts t ON t.restaurant_id=s.id
LEFT JOIN menu_counts m ON m.restaurant_id=s.id
LEFT JOIN station_counts a ON a.restaurant_id=s.id ORDER BY s.id;

-- Older migrations use short numeric versions; lexical MAX(version) is not a head.
SELECT version,name FROM supabase_migrations.schema_migrations
WHERE version ~ '^[0-9]{14}$' ORDER BY version DESC LIMIT 15;

SELECT p.oid::regprocedure::text AS signature,md5(pg_get_functiondef(p.oid)) AS definition_hash,
  p.prosecdef AS security_definer,p.proconfig AS settings
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN (
  'process_payment','cashier_move_order_items','cashier_cancel_item_quantity',
  'direct_order_prepare_combo_items','kds_can_access_topic',
  'admin_apply_store_opening_config_v3','kds_record_station_progress_v3',
  'kds_record_direct_preparation_v1','kds_complete_kitchen_batch_v1',
  'kds_complete_customer_delivery_batch_v1','emergency_sync_combo_component_items')
ORDER BY signature;
ROLLBACK;
