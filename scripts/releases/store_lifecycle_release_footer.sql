-- Compare the existing rows only; concurrently committed new receipts do not
-- change these immutable anchors. Nothing is written to a sales/payment ledger.
DO $preserve$
BEGIN
 IF EXISTS(SELECT 1 FROM lifecycle_store_anchors a LEFT JOIN public.restaurants r USING(id) WHERE r.id IS NULL OR a.fingerprint<>md5(jsonb_build_array(r.name,r.address,r.is_active,r.brand_id,r.tax_entity_id,r.short_code)::text))
 OR EXISTS(SELECT 1 FROM lifecycle_settings_anchors a LEFT JOIN public.restaurant_settings s USING(restaurant_id) WHERE s.restaurant_id IS NULL OR a.fingerprint<>md5(jsonb_build_array(s.kds_workflow,s.fulfillment_mode,to_jsonb(s)->'floor_direct_beverage_enabled')::text))
 OR EXISTS(SELECT 1 FROM lifecycle_user_anchors a LEFT JOIN public.users u USING(id) WHERE u.id IS NULL OR a.fingerprint<>md5(jsonb_build_array(u.auth_id,u.restaurant_id,u.brand_id,u.role,u.account_type,u.fixed_account_code,u.is_active)::text))
 OR EXISTS(SELECT 1 FROM lifecycle_assignment_anchors a LEFT JOIN public.emergency_station_assignments s USING(id) WHERE s.id IS NULL OR a.fingerprint<>md5(jsonb_build_array(s.restaurant_id,s.user_id,s.station_type,s.floor_label,s.is_active)::text))
 OR EXISTS(SELECT 1 FROM lifecycle_menu_anchors a LEFT JOIN public.menu_items m USING(id) WHERE m.id IS NULL OR a.fingerprint<>md5(jsonb_build_array(m.restaurant_id,m.name,m.name_vi,m.name_en,m.price,m.effective_vat_rate,m.is_archived,m.is_available,to_jsonb(m)->'size_prices',to_jsonb(m)->'meal_choices')::text))
 OR EXISTS(SELECT 1 FROM lifecycle_receipt_anchors a LEFT JOIN public.digital_receipts r USING(id) WHERE r.id IS NULL OR a.fingerprint<>md5(r.snapshot::text)) THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_EXISTING_DATA_DRIFT';
 END IF;
END $preserve$;
-- The official deploy gate records the bundle version after this transaction.
-- Component history is recorded atomically with the actual component DDL.
INSERT INTO supabase_migrations.schema_migrations(version,name,statements)
 SELECT version,name,ARRAY['Applied by atomic lifecycle release 20261022200000; canonical SHA256='||sha256] FROM lifecycle_release_components;
