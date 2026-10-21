-- Service-area codes are independent of physical floors. Legacy store mapping
-- remains unchanged; newly registered areas are routed by their stable code.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.emergency_order_queue DROP CONSTRAINT emergency_order_queue_floor_label_check;
ALTER TABLE public.emergency_order_queue ADD CONSTRAINT emergency_order_queue_floor_label_check CHECK(floor_label ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$');
ALTER TABLE public.emergency_station_assignments DROP CONSTRAINT emergency_station_floor_contract;
ALTER TABLE public.emergency_station_assignments ADD CONSTRAINT emergency_station_floor_contract CHECK(
 (station_type='floor' AND floor_label IS NOT NULL AND floor_label ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$') OR (station_type<>'floor' AND floor_label IS NULL));
ALTER TABLE public.emergency_tray_floor_batch_actions DROP CONSTRAINT emergency_tray_floor_batch_actions_floor_label_check;
ALTER TABLE public.emergency_tray_floor_batch_actions ADD CONSTRAINT emergency_tray_floor_batch_actions_floor_label_check CHECK(floor_label ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$');
ALTER TABLE public.kds_change_log DROP CONSTRAINT kds_change_log_floor_target;
ALTER TABLE public.kds_change_log ADD CONSTRAINT kds_change_log_floor_target CHECK(target_floor_label IS NULL OR target_floor_label ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$');
ALTER TABLE public.kds_shadow_health DROP CONSTRAINT kds_shadow_health_floor_key_check;
ALTER TABLE public.kds_shadow_health ADD CONSTRAINT kds_shadow_health_floor_key_check CHECK(floor_key='' OR floor_key ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$');
ALTER FUNCTION public.emergency_floor_label(uuid,text,text) RENAME TO emergency_floor_label_legacy;
CREATE FUNCTION public.emergency_floor_label(p_store_id uuid,p_floor_label text,p_table_number text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT coalesce((SELECT a.stored_code FROM public.store_service_areas a
 JOIN public.store_registration_requests r ON r.store_id=a.restaurant_id
 WHERE a.restaurant_id=p_store_id AND a.stored_code=upper(btrim(p_floor_label))),
 public.emergency_floor_label_legacy(p_store_id,p_floor_label,p_table_number));
$$;
REVOKE ALL ON FUNCTION public.emergency_floor_label(uuid,text,text),public.emergency_floor_label_legacy(uuid,text,text) FROM PUBLIC,anon,authenticated,service_role;

DO $$ DECLARE definition text; BEGIN
 definition:=pg_get_functiondef('public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure);
 IF position('v_floor_label NOT IN (''1F'', ''2F'', ''3F'')' IN definition)=0 THEN RAISE EXCEPTION 'AREA_DISPATCH_PATCH_MISMATCH'; END IF;
 definition:=replace(definition,'v_floor_label NOT IN (''1F'', ''2F'', ''3F'')',
  'v_floor_label IS NULL OR v_floor_label !~ ''^[A-Z0-9][A-Z0-9_-]{0,15}$''');
 EXECUTE definition;
 -- Broadcast reset events to actual assigned areas with a single bounded query.
 definition:=pg_get_functiondef('public.kds_broadcast_change()'::regprocedure);
 IF position('FROM unnest(ARRAY[''1F'',''2F'',''3F'']) f' IN definition)=0 THEN RAISE EXCEPTION 'AREA_BROADCAST_PATCH_MISMATCH'; END IF;
 definition:=replace(definition,'FROM unnest(ARRAY[''1F'',''2F'',''3F'']) f',
 'FROM (SELECT DISTINCT floor_label AS f FROM public.emergency_station_assignments WHERE restaurant_id=v_change.restaurant_id AND station_type=''floor'' AND is_active) areas');
 EXECUTE definition;
END $$;

CREATE FUNCTION public.admin_get_store_service_areas_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'code',stored_code,'name',coalesce(display_name,stored_code),'physical_floor',physical_floor) ORDER BY stored_code),'[]')
 INTO result FROM (SELECT * FROM store_service_areas WHERE restaurant_id=p_store_id ORDER BY stored_code LIMIT 100) a;
 RETURN jsonb_build_object('registered',EXISTS(SELECT 1 FROM store_registration_requests WHERE store_id=p_store_id),'areas',result);
END $$;
REVOKE ALL ON FUNCTION public.admin_get_store_service_areas_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_service_areas_v1(uuid) TO authenticated;

CREATE FUNCTION public.store_registration_table_area_guard_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM registered_table_rows t
 JOIN public.store_registration_requests r ON r.store_id=t.restaurant_id
 LEFT JOIN public.store_service_areas a ON a.restaurant_id=t.restaurant_id AND a.stored_code=t.floor_label
 WHERE a.id IS NULL) THEN RAISE EXCEPTION 'REGISTERED_SERVICE_AREA_REQUIRED'; END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.store_registration_table_area_guard_v1() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER store_registration_table_area_insert AFTER INSERT ON public.tables
 REFERENCING NEW TABLE AS registered_table_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_registration_table_area_guard_v1();
CREATE TRIGGER store_registration_table_area_update AFTER UPDATE ON public.tables
 REFERENCING NEW TABLE AS registered_table_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_registration_table_area_guard_v1();
CREATE FUNCTION public.store_registered_pickup_only_v1(p_store_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM store_account_onboarding_jobs j JOIN store_registration_requests r ON r.store_id=j.store_id
 WHERE j.store_id=p_store_id AND j.input->'config'->>'dine_in'='false');
$$;
REVOKE ALL ON FUNCTION public.store_registered_pickup_only_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;
DO $$ DECLARE definition text; BEGIN
 definition:=pg_get_functiondef('public.admin_validate_store_opening_config_v2(uuid,jsonb,jsonb,text)'::regprocedure);
 IF position('IF v_table_count = 0 THEN' IN definition)=0 THEN RAISE EXCEPTION 'PICKUP_VALIDATION_PATCH_MISMATCH'; END IF;
 definition:=replace(definition,'IF v_table_count = 0 THEN','IF v_table_count = 0 AND NOT public.store_registered_pickup_only_v1(p_store_id) THEN');
 EXECUTE definition;
 definition:=pg_get_functiondef('public.admin_get_store_opening_readiness(uuid)'::regprocedure);
 IF position('v_table_count > 0' IN definition)=0 THEN RAISE EXCEPTION 'PICKUP_READINESS_PATCH_MISMATCH'; END IF;
 EXECUTE replace(definition,'v_table_count > 0','(v_table_count > 0 OR public.store_registered_pickup_only_v1(p_store_id))');
END $$;
COMMIT;
