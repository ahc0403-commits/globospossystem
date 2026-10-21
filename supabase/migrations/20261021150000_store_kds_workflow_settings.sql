-- Per-store service workflow. Preserve every existing queue's source snapshot.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
ALTER TABLE public.restaurant_settings ADD COLUMN kds_workflow text NOT NULL
 DEFAULT 'kitchen_tray_floor' CHECK (kds_workflow IN ('kitchen_tray_floor','kitchen_floor'));
UPDATE public.restaurant_settings SET kds_workflow='kitchen_floor'
 WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849';
-- Historical snapshots must not acquire a dependency on today's mutable setting.
ALTER TABLE public.emergency_order_queue DROP CONSTRAINT kds_direct_floor_store_scope;

-- An uncorrelated initplan loads the small configured store set once per SQL
-- statement. Keep the predicate inlineable for policies and set-based readers.
CREATE FUNCTION public.kds_direct_floor_store_ids() RETURNS uuid[]
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT coalesce(array_agg(restaurant_id),'{}'::uuid[])
 FROM public.restaurant_settings WHERE kds_workflow='kitchen_floor';
$$;
REVOKE ALL ON FUNCTION public.kds_direct_floor_store_ids() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.kds_direct_floor_store_ids() TO authenticated,service_role;
-- Keep kds_is_direct_floor_store as JeonGabok's immutable identity predicate:
-- guest floor labels and the permanently retired checker are store-specific.
CREATE FUNCTION public.kds_uses_direct_floor_workflow(p_store_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT coalesce(p_store_id=ANY(public.kds_direct_floor_store_ids()),false);
$$;
REVOKE ALL ON FUNCTION public.kds_uses_direct_floor_workflow(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.kds_uses_direct_floor_workflow(uuid) TO authenticated,service_role;

-- Replace only workflow decisions in the effective readers/writers. Row-based
-- predicates use an uncorrelated initplan; identity/account/label rules stay intact.
DO $patch$
DECLARE target record; definition text; changed text;
BEGIN
 FOR target IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f' AND p.proname=ANY(ARRAY[
  'emergency_record_progress','sync_direct_delivery_ticket_from_kds','kds_record_station_progress_v3',
  'kds_apply_station_progress_batch_v1','enqueue_tray_copy_for_kitchen_job','emergency_revert_order_action',
  'kds_direct_filter_targets','kds_record_direct_kitchen_v1','get_emergency_station_snapshot',
  'emergency_advance_leftover_packaging','emergency_complete_order_stage','emergency_add_order_batch_timings',
  'emergency_record_combo_component_progress','kds_record_direct_preparation_v1',
  'get_kds_ticket_v2_pre_business_day','kds_broadcast_change','kds_capture_fulfillment_event','get_emergency_station_timings'
 ]) AND p.prosrc LIKE '%kds_is_direct_floor_store%' LOOP
  definition:=pg_get_functiondef(target.oid);
  changed:=regexp_replace(definition,
   'public\.kds_is_direct_floor_store\(([a-z][a-z0-9_]*\.(restaurant_id|store_id))\)',
   'COALESCE(\1 = ANY((SELECT public.kds_direct_floor_store_ids())::uuid[]), false)','g');
  changed:=replace(changed,'public.kds_is_direct_floor_store(', 'public.kds_uses_direct_floor_workflow(');
  EXECUTE changed;
 END LOOP;
END;
$patch$;

CREATE FUNCTION public.kds_store_workflow_errors(p_store_id uuid,p_workflow text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE current_workflow text;
BEGIN
 IF p_workflow IS NULL OR p_workflow NOT IN ('kitchen_tray_floor','kitchen_floor') THEN
  RETURN '["STORE_SETUP_WORKFLOW_INVALID"]'::jsonb;
 END IF;
 IF p_store_id='273b057e-3b69-46e3-93c1-6194c2802849' AND p_workflow<>'kitchen_floor' THEN
  RETURN '["STORE_SETUP_WORKFLOW_JEONGABOK"]'::jsonb;
 END IF;
 SELECT kds_workflow INTO current_workflow FROM public.restaurant_settings WHERE restaurant_id=p_store_id;
 current_workflow:=coalesce(current_workflow,CASE WHEN p_store_id='273b057e-3b69-46e3-93c1-6194c2802849'
  THEN 'kitchen_floor' ELSE 'kitchen_tray_floor' END);
 IF current_workflow=p_workflow THEN RETURN '[]'::jsonb; END IF;
 IF NOT coalesce(public.is_super_admin(),false) THEN RETURN '["STORE_SETUP_WORKFLOW_PERMISSION"]'::jsonb; END IF;
 IF EXISTS(SELECT 1 FROM public.orders WHERE restaurant_id=p_store_id AND status NOT IN ('completed','cancelled'))
 OR EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i
  JOIN public.emergency_fulfillment_sessions s ON s.id=i.session_id AND s.status='active'
  WHERE i.restaurant_id=p_store_id AND NOT i.is_cancelled AND i.floor_served_quantity<i.ordered_quantity-i.excused_quantity)
 OR EXISTS(SELECT 1 FROM public.emergency_floor_direct_items i
  JOIN public.emergency_fulfillment_sessions s ON s.id=i.session_id AND s.status='active'
  WHERE i.restaurant_id=p_store_id AND NOT i.is_cancelled AND i.floor_served_quantity<i.ordered_quantity-i.excused_quantity)
 OR EXISTS(SELECT 1 FROM public.leftover_packaging_requests WHERE restaurant_id=p_store_id AND status NOT IN ('completed','cancelled')) THEN
  RETURN '["STORE_SETUP_WORKFLOW_BUSY"]'::jsonb;
 END IF;
 RETURN '[]'::jsonb;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_store_workflow_errors(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.kds_guard_store_workflow_setting() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE errors jsonb;
BEGIN
 IF TG_OP='INSERT' AND NEW.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' THEN
  NEW.kds_workflow:='kitchen_floor';
 END IF;
 IF TG_OP='UPDATE' AND OLD.kds_workflow=NEW.kds_workflow THEN RETURN NEW; END IF;
 IF TG_OP='INSERT' AND NEW.kds_workflow='kitchen_tray_floor' THEN RETURN NEW; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||NEW.restaurant_id::text,0));
 PERFORM public.require_admin_actor_for_restaurant(NEW.restaurant_id);
 errors:=public.kds_store_workflow_errors(NEW.restaurant_id,NEW.kds_workflow);
 IF jsonb_array_length(errors)>0 THEN RAISE EXCEPTION USING MESSAGE='STORE_SETUP_CONFIG_INVALID',DETAIL=errors::text; END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_guard_store_workflow_setting() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER kds_guard_store_workflow_setting BEFORE INSERT OR UPDATE OF kds_workflow
 ON public.restaurant_settings FOR EACH ROW EXECUTE FUNCTION public.kds_guard_store_workflow_setting();

CREATE OR REPLACE FUNCTION public.kds_assign_direct_floor_workflow() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||NEW.restaurant_id::text,0));
 NEW.kitchen_direct_to_floor:=public.kds_uses_direct_floor_workflow(NEW.restaurant_id);
 RETURN NEW;
END;
$$;

CREATE FUNCTION public.admin_validate_store_opening_config_v3(
 p_store_id uuid,p_tables jsonb,p_destinations jsonb,p_mode text,p_kds_workflow text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; errors jsonb;
BEGIN
 result:=public.admin_validate_store_opening_config_v2(p_store_id,p_tables,p_destinations,p_mode);
 errors:=coalesce(result->'errors','[]'::jsonb)||public.kds_store_workflow_errors(p_store_id,p_kds_workflow);
 RETURN result||jsonb_build_object('valid',jsonb_array_length(errors)=0,'errors',errors,'kds_workflow',p_kds_workflow);
END;
$$;
CREATE FUNCTION public.admin_apply_store_opening_config_v3(
 p_store_id uuid,p_tables jsonb,p_destinations jsonb,p_mode text,p_kds_workflow text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE validation jsonb; result jsonb; previous text;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id::text,0));
 PERFORM 1 FROM public.restaurants WHERE id=p_store_id FOR UPDATE;
 SELECT kds_workflow INTO previous FROM public.restaurant_settings WHERE restaurant_id=p_store_id FOR UPDATE;
 validation:=public.admin_validate_store_opening_config_v3(p_store_id,p_tables,p_destinations,p_mode,p_kds_workflow);
 IF NOT coalesce((validation->>'valid')::boolean,false) THEN
  RAISE EXCEPTION USING MESSAGE='STORE_SETUP_CONFIG_INVALID',DETAIL=(validation->'errors')::text;
 END IF;
 result:=public.admin_apply_store_opening_config_v2(p_store_id,p_tables,p_destinations,p_mode);
 UPDATE public.restaurant_settings SET kds_workflow=p_kds_workflow,updated_at=now()
  WHERE restaurant_id=p_store_id AND kds_workflow IS DISTINCT FROM p_kds_workflow;
 IF NOT FOUND AND NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id=p_store_id) THEN
  INSERT INTO public.restaurant_settings(restaurant_id,kds_workflow) VALUES(p_store_id,p_kds_workflow);
 END IF;
 IF previous IS DISTINCT FROM p_kds_workflow THEN
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  VALUES(auth.uid(),'store_service_workflow_changed','restaurants',p_store_id,
   jsonb_build_object('before',previous,'after',p_kds_workflow));
 END IF;
 RETURN result||jsonb_build_object('kds_workflow',p_kds_workflow);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_validate_store_opening_config_v3(uuid,jsonb,jsonb,text,text),
 public.admin_apply_store_opening_config_v3(uuid,jsonb,jsonb,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_validate_store_opening_config_v3(uuid,jsonb,jsonb,text,text),
 public.admin_apply_store_opening_config_v3(uuid,jsonb,jsonb,text,text) TO authenticated,service_role;

DO $$
BEGIN
 IF NOT public.kds_uses_direct_floor_workflow('273b057e-3b69-46e3-93c1-6194c2802849')
 OR public.kds_uses_direct_floor_workflow('8bc9eef5-dcd5-46b1-b931-23f77132322c')
 OR public.kds_uses_direct_floor_workflow(NULL)
 OR has_function_privilege('anon','public.admin_apply_store_opening_config_v3(uuid,jsonb,jsonb,text,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.kds_store_workflow_errors(uuid,text)','EXECUTE') THEN
  RAISE EXCEPTION 'STORE_KDS_WORKFLOW_POSTCONDITION_FAILED';
 END IF;
END;
$$;
COMMIT;
