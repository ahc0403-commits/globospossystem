-- One receiver/device may explicitly serve several areas. Preserve the legacy
-- primary floor and every existing assignment; no all-store fallback authority.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.emergency_station_assignments ADD COLUMN service_area_codes text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.emergency_station_assignments ADD CONSTRAINT station_service_areas_bound CHECK(cardinality(service_area_codes)<=16 AND (cardinality(service_area_codes)=0 OR station_type='floor' AND floor_label=ANY(service_area_codes)));
ALTER TABLE public.store_registration_station_bindings DROP CONSTRAINT store_registration_station_bindings_pkey;
ALTER TABLE public.store_registration_station_bindings ADD PRIMARY KEY(restaurant_id,account_code,station_id);
CREATE FUNCTION public.store_assignment_area_codes_v1(a public.emergency_station_assignments) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$ SELECT coalesce(nullif(a.service_area_codes,'{}'::text[]),ARRAY[a.floor_label]); $$;
REVOKE ALL ON FUNCTION public.store_assignment_area_codes_v1(public.emergency_station_assignments) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.store_guard_receiver_areas_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF cardinality(NEW.service_area_codes)>0 AND EXISTS(SELECT 1 FROM unnest(NEW.service_area_codes)code LEFT JOIN store_service_areas a ON a.restaurant_id=NEW.restaurant_id AND a.stored_code=code WHERE a.id IS NULL) THEN RAISE EXCEPTION 'SERVICE_AREA_SCOPE_INVALID'; END IF;
 IF TG_OP='UPDATE' AND NEW.service_area_codes IS DISTINCT FROM OLD.service_area_codes THEN
  IF EXISTS(SELECT 1 FROM orders WHERE restaurant_id=NEW.restaurant_id AND status IN('pending','confirmed','serving')) THEN RAISE EXCEPTION 'WORKFLOW_DRAIN_REQUIRED'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER store_receiver_areas_guard BEFORE INSERT OR UPDATE ON public.emergency_station_assignments FOR EACH ROW EXECUTE FUNCTION public.store_guard_receiver_areas_v1();
REVOKE ALL ON FUNCTION public.store_guard_receiver_areas_v1() FROM PUBLIC,anon,authenticated,service_role;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.store_registration_config_v1(jsonb)'::regprocedure);
 d:=replace(d,'''physical_floor'',nullif(btrim(a->>''physical_floor''),''''))', '''physical_floor'',nullif(btrim(a->>''physical_floor''),''''),''receiver'',coalesce(a->>''receiver'',a->>''code''))');
 d:=replace(d,'OR length(btrim(coalesce(a->>''name'','''')))', 'OR coalesce(a->>''receiver'',a->>''code'','''') !~ ''^[A-Z0-9][A-Z0-9_-]{0,15}$'' OR length(btrim(coalesce(a->>''name'','''')))'); EXECUTE d;
 d:=pg_get_functiondef('public.admin_preview_store_registration_v1(uuid,uuid,jsonb,text)'::regprocedure);
 d:=replace(d,'lower(a->>''code''),''device_emergency_station'',''emergency_station'',a->>''name'',''store'' FROM jsonb_array_elements(cfg->''areas'')a', 'lower(a->>''receiver''),''device_emergency_station'',''emergency_station'',string_agg(a->>''name'','' / '' ORDER BY a->>''code''),''store'' FROM jsonb_array_elements(cfg->''areas'')a GROUP BY a->>''receiver'''); EXECUTE d;
 d:=pg_get_functiondef('public.admin_register_store_v1(uuid,jsonb)'::regprocedure);
 d:=replace(d,'IF job.input<>input OR', 'IF (job.input||jsonb_build_object(''config'',store_registration_config_v1(job.input->''config'')))<>input OR');
 d:=replace(d,$patch$CASE WHEN input->>'account_naming'='legacy' THEN '_floor_' ELSE '_area_' END||lower(a.stored_code) END$patch$, $patch$CASE WHEN input->>'account_naming'='legacy' THEN '_floor_'||lower(a.stored_code) ELSE '_area_'||lower(area_config.receiver) END END$patch$);
 d:=replace(d,'LEFT JOIN store_service_areas a ON a.id=s.area_id WHERE s.restaurant_id=store.id;', 'LEFT JOIN store_service_areas a ON a.id=s.area_id LEFT JOIN jsonb_to_recordset(cfg->''areas'') area_config(code text,receiver text) ON area_config.code=a.stored_code WHERE s.restaurant_id=store.id;'); EXECUTE d;
 d:=pg_get_functiondef('public.sync_emergency_station_assignment_for_user()'::regprocedure);
 d:=replace(d,'  SELECT s.kind,a.stored_code INTO v_station,v_floor FROM', '  SELECT min(s.kind),min(a.stored_code) INTO v_station,v_floor FROM');
 d:=replace(d,'  IF FOUND THEN', '  IF v_station IS NOT NULL THEN');
 d:=replace(d,'    RETURN NEW;
  END IF;
  IF NEW.fixed_account_code', '    UPDATE public.emergency_station_assignments SET service_area_codes=CASE WHEN v_station=''floor'' THEN ARRAY(SELECT a.stored_code FROM public.store_registration_station_bindings b JOIN public.store_service_stations s ON s.id=b.station_id JOIN public.store_service_areas a ON a.id=s.area_id WHERE b.restaurant_id=NEW.restaurant_id AND b.account_code=NEW.fixed_account_code ORDER BY a.stored_code) ELSE ARRAY[]::text[] END WHERE restaurant_id=NEW.restaurant_id AND user_id=NEW.id; RETURN NEW;
  END IF;
  IF NEW.fixed_account_code'); EXECUTE d;
END $$;
-- Rewrite a reviewed, finite set of effective functions. Array membership is
-- evaluated against the one already-loaded assignment (no per-ticket lookup).
DO $$ DECLARE name text; f regprocedure; d text; BEGIN
 FOREACH name IN ARRAY ARRAY[
  'emergency_complete_order_stage','emergency_complete_route_order_stage','emergency_revert_order_action','emergency_revert_route_order_action',
  'emergency_record_combo_component_progress','emergency_record_progress','emergency_record_floor_direct_progress','emergency_advance_leftover_packaging',
  'get_emergency_station_snapshot_base','get_emergency_station_snapshot_pre_batch_timing','get_emergency_station_timings','get_emergency_station_today_completed_base',
  'get_kds_ticket_v2_pre_business_day','kds_record_station_progress_v3','kds_serve_ready_order_v3','kds_can_access_topic','get_kds_sync_config'] LOOP
  SELECT oid::regprocedure INTO STRICT f FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=name;
  d:=pg_get_functiondef(f);
  d:=replace(d,'v_assignment.floor_label <> v_queue.floor_label','NOT (v_queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment)))');
  d:=replace(d,'v_queue.floor_label <> v_assignment.floor_label','NOT (v_queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment)))');
  d:=replace(d,'v_assignment.floor_label <> v_request.floor_label','NOT (v_request.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment)))');
  d:=replace(d,'queue.floor_label = v_assignment.floor_label','queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment))');
  d:=replace(d,'request.floor_label = v_assignment.floor_label','request.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment))');
  d:=replace(d,'v_assignment.floor_label = v_floor','v_floor=ANY(public.store_assignment_area_codes_v1(v_assignment))');
  d:=replace(d,'''floor_label'', v_assignment.floor_label,','''floor_label'', v_assignment.floor_label,''service_area_configuration_known'',EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=v_assignment.restaurant_id AND input?''config''),''service_area_codes'',CASE WHEN v_assignment.station_type=''tray'' AND EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=v_assignment.restaurant_id AND input?''config'') THEN coalesce((SELECT jsonb_agg(stored_code ORDER BY stored_code) FROM store_service_areas WHERE restaurant_id=v_assignment.restaurant_id),''[]''::jsonb) ELSE to_jsonb(public.store_assignment_area_codes_v1(v_assignment)) END,');
  d:=replace(d,'v_assignment.floor_label, ''complete''','v_queue.floor_label, ''complete''');
  d:=replace(d,'''floor'', v_assignment.floor_label,','''floor'', v_queue.floor_label,');
  EXECUTE d;
 END LOOP;
 d:=pg_get_functiondef('public.get_kds_changes_v2(bigint,integer)'::regprocedure);
 d:=replace(d,'change_row.target_floor_label = v_floor','coalesce(v_config->''service_area_codes'',jsonb_build_array(v_floor)) ? change_row.target_floor_label'); EXECUTE d;
 d:=pg_get_functiondef('public.emergency_enqueue_push(uuid,uuid,uuid,text,text,text)'::regprocedure);
 d:=replace(d,'assignment.floor_label = p_floor_label','p_floor_label=ANY(public.store_assignment_area_codes_v1(assignment))');
 d:=replace(d,'assignment.station_type, assignment.floor_label, p_order_id','assignment.station_type, p_floor_label, p_order_id'); EXECUTE d;
 d:=pg_get_functiondef('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
 IF position('assignment.floor_label = event_rows.floor_label' IN d)=0 THEN RAISE EXCEPTION 'SHARED_AREA_PUSH_PATCH_MISMATCH'; END IF;
 d:=replace(d,'assignment.floor_label = event_rows.floor_label','event_rows.floor_label=ANY(public.store_assignment_area_codes_v1(assignment))');
 d:=replace(d,'assignment.station_type, assignment.floor_label,','assignment.station_type, event_rows.floor_label,'); EXECUTE d;
 d:=pg_get_functiondef('public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'::regprocedure);
 d:=replace(d,'  v_hash := md5(', '  SELECT min(q.floor_label) INTO v_floor_label FROM public.emergency_order_queue q JOIN jsonb_to_recordset(p_allocations)a(queue_id uuid) ON a.queue_id=q.id WHERE q.restaurant_id=v_assignment.restaurant_id HAVING count(DISTINCT q.floor_label)=1; IF v_floor_label IS NULL OR NOT (v_floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment))) THEN RAISE EXCEPTION ''EMERGENCY_STAGE_FORBIDDEN''; END IF; v_hash := md5('); EXECUTE d;
 d:=pg_get_functiondef('public.admin_get_store_lifecycle_v1(uuid)'::regprocedure);
 d:=replace(d,'a.floor_label=area.stored_code','area.stored_code=ANY(public.store_assignment_area_codes_v1(a))'); EXECUTE d;
 d:=pg_get_functiondef('public.store_operating_source_v1(uuid)'::regprocedure);
 d:=replace(d,'''user_store_id'',u.restaurant_id) ORDER BY a.id','''user_store_id'',u.restaurant_id)||CASE WHEN cardinality(a.service_area_codes)>1 THEN jsonb_build_object(''service_area_codes'',to_jsonb(a.service_area_codes)) ELSE ''{}''::jsonb END ORDER BY a.id');
 d:=replace(d,'SELECT id,user_id,station_type,floor_label FROM','SELECT id,user_id,station_type,floor_label,service_area_codes FROM'); EXECUTE d;
END $$;
COMMIT;
