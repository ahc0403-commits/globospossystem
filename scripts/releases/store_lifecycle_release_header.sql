-- The dependencies are one transaction because later guards/receiving commands
-- depend on the preceding definitions. No client sees a partially replaced API.
DO $history$
BEGIN
 IF EXISTS(SELECT 1 FROM lifecycle_release_components c JOIN supabase_migrations.schema_migrations m USING(version)) THEN
  RAISE EXCEPTION 'LIFECYCLE_COMPONENT_ALREADY_APPLIED';
 END IF;
END $history$;
CREATE TEMP TABLE lifecycle_store_anchors ON COMMIT DROP AS
 SELECT id,md5(jsonb_build_array(name,address,is_active,brand_id,tax_entity_id,short_code)::text) fingerprint FROM public.restaurants;
CREATE TEMP TABLE lifecycle_settings_anchors ON COMMIT DROP AS
 SELECT restaurant_id,md5(jsonb_build_array(kds_workflow,fulfillment_mode,to_jsonb(s)->'floor_direct_beverage_enabled')::text) fingerprint FROM public.restaurant_settings s;
CREATE TEMP TABLE lifecycle_user_anchors ON COMMIT DROP AS
 SELECT id,md5(jsonb_build_array(auth_id,restaurant_id,brand_id,role,account_type,fixed_account_code,is_active)::text) fingerprint FROM public.users;
CREATE TEMP TABLE lifecycle_assignment_anchors ON COMMIT DROP AS
 SELECT id,md5(jsonb_build_array(restaurant_id,user_id,station_type,floor_label,is_active)::text) fingerprint FROM public.emergency_station_assignments;
CREATE TEMP TABLE lifecycle_menu_anchors ON COMMIT DROP AS
 SELECT id,md5(jsonb_build_array(restaurant_id,name,name_vi,name_en,price,effective_vat_rate,is_archived,is_available,to_jsonb(m)->'size_prices',to_jsonb(m)->'meal_choices')::text) fingerprint FROM public.menu_items m;
CREATE TEMP TABLE lifecycle_receipt_anchors ON COMMIT DROP AS
 SELECT id,md5(snapshot::text) fingerprint FROM public.digital_receipts;
