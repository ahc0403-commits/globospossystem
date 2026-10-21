-- Scoped discovery retains legacy snapshots only for stores that have not switched.
-- production-gate: self-verifying
BEGIN;
CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE payload jsonb; workflow jsonb;
BEGIN
 payload:=public.get_emergency_station_snapshot_pre_direct();
 IF payload->>'restaurant_id' IS NOT NULL THEN
  workflow:=public.store_workflow_device_v1((payload->>'restaurant_id')::uuid);
  payload:=payload||jsonb_build_object('operating_workflow',workflow);
  IF workflow->>'active_id' IS NOT NULL AND payload->>'station_type'='kitchen' THEN
   payload:=payload||jsonb_build_object('orders','[]'::jsonb,'completed_orders','[]'::jsonb);
   IF workflow->'station'->>'id' IS DISTINCT FROM (SELECT coalesce(r.definition->>'packaging_station_id',r.definition->'default_path'->>0) FROM public.store_workflow_releases r WHERE r.id=(workflow->>'active_id')::uuid) THEN payload:=payload||jsonb_build_object('leftover_packaging_tasks','[]'::jsonb); END IF;
  END IF;
 END IF;
 RETURN payload||jsonb_build_object('kitchen_direct_to_floor',public.kds_uses_direct_floor_workflow((payload->>'restaurant_id')::uuid));
END;
$$;
CREATE FUNCTION public.store_workflow_notify(p_store_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE station record;
BEGIN
 -- At most eight station invalidations, independent of the number of order lines.
 FOR station IN SELECT c.active_id,s->>'id' id FROM public.store_workflow_configs c JOIN public.store_workflow_releases r ON r.id=c.active_id,jsonb_array_elements(r.definition->'stations')s WHERE c.restaurant_id=p_store_id LOOP
  PERFORM realtime.send(jsonb_build_object('release_id',station.active_id),'changed','workflow:'||p_store_id||':'||station.id||':'||station.active_id,true);
 END LOOP;
END;
$$;
-- Coalesce preparation readiness into at most one event per affected station and
-- session, then reuse the existing push delivery/lease/dispatch infrastructure.
CREATE FUNCTION public.store_preparation_ready_notify(p_order_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 WITH ready AS MATERIALIZED (
  SELECT t.restaurant_id,t.release_id,t.order_id,s.station_id,q.session_id,s.id,coalesce(prev.done,src.quantity)-s.started quantity
  FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id
  JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
  JOIN public.emergency_order_queue q ON q.id=src.queue_id
  LEFT JOIN public.store_preparation_steps prev ON prev.task_id=t.id AND prev.position=s.position-1
  WHERE t.order_id=ANY(p_order_ids) AND NOT src.blocked AND coalesce(prev.done,src.quantity)>s.started
 ), grouped AS (
  SELECT restaurant_id,release_id,station_id,session_id,(array_agg(order_id ORDER BY order_id))[1] order_id,
   sum(quantity)::integer quantity,md5(station_id::text||jsonb_agg(jsonb_build_array(id,quantity) ORDER BY id)::text)::uuid event_id
  FROM ready GROUP BY restaurant_id,release_id,station_id,session_id
 ), added AS (
  INSERT INTO public.emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,stage,delta,details)
  SELECT event_id,session_id,restaurant_id,order_id,'order_received',quantity,
   jsonb_build_object('workflow_station_id',station_id,'workflow_release_id',release_id) FROM grouped
  ON CONFLICT(event_id) DO NOTHING RETURNING *
 ) INSERT INTO public.emergency_push_deliveries(event_id,restaurant_id,device_id,push_token,station_type,floor_label,order_id,stage)
 SELECT e.event_id,e.restaurant_id,d.id,d.token,'kitchen',NULL,e.order_id,e.stage
 FROM added e JOIN public.store_workflow_releases r ON r.id=(e.details->>'workflow_release_id')::uuid,
 jsonb_array_elements(r.definition->'stations')station
 JOIN public.emergency_station_assignments a ON a.is_active AND a.station_type='kitchen' AND station->'user_ids' ? a.user_id::text
 JOIN public.emergency_web_push_devices d ON d.station_assignment_id=a.id AND d.is_enabled
 WHERE station->>'id'=e.details->>'workflow_station_id' AND a.restaurant_id=e.restaurant_id AND d.restaurant_id=e.restaurant_id
 ON CONFLICT(event_id,device_id) DO NOTHING;
 PERFORM public.store_workflow_notify(restaurant_id) FROM (SELECT DISTINCT restaurant_id FROM public.orders WHERE id=ANY(p_order_ids)) stores;
END;
$$;
REVOKE ALL ON FUNCTION public.store_preparation_ready_notify(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.store_workflow_settings_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF (NEW.fulfillment_mode IS DISTINCT FROM OLD.fulfillment_mode OR NEW.kds_workflow IS DISTINCT FROM OLD.kds_workflow)
 AND EXISTS(SELECT 1 FROM public.store_workflow_configs WHERE restaurant_id=NEW.restaurant_id AND active_id IS NOT NULL)
 THEN RAISE EXCEPTION 'WORKFLOW_DEACTIVATE_FIRST'; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER workflow_settings_guard BEFORE UPDATE ON public.restaurant_settings FOR EACH ROW EXECUTE FUNCTION public.store_workflow_settings_guard();
CREATE FUNCTION public.store_workflow_assignment_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.store_workflow_configs c WHERE c.restaurant_id=coalesce(NEW.restaurant_id,OLD.restaurant_id) AND c.active_id IS NOT NULL)
 AND (TG_OP<>'UPDATE' OR (NEW.user_id,NEW.station_type,NEW.floor_label,NEW.is_active) IS DISTINCT FROM (OLD.user_id,OLD.station_type,OLD.floor_label,OLD.is_active))
 THEN RAISE EXCEPTION 'WORKFLOW_DEACTIVATE_FIRST'; END IF;
 RETURN coalesce(NEW,OLD);
END;
$$;
CREATE TRIGGER workflow_assignment_guard BEFORE INSERT OR UPDATE OR DELETE ON public.emergency_station_assignments FOR EACH ROW EXECUTE FUNCTION public.store_workflow_assignment_guard();
REVOKE ALL ON FUNCTION public.store_workflow_notify(uuid),public.store_workflow_settings_guard(),public.store_workflow_assignment_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION "public"."kds_can_access_topic"("p_topic" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_parts text[] := string_to_array(COALESCE(p_topic, ''), ':');
  v_store_id uuid;
  v_station text;
  v_floor text;
  v_assignment public.emergency_station_assignments%ROWTYPE;
BEGIN
  IF cardinality(v_parts)=4 AND v_parts[1]='workflow' THEN
   RETURN EXISTS(SELECT 1 FROM public.users u JOIN public.emergency_station_assignments a ON a.user_id=u.id AND a.is_active AND a.station_type='kitchen'
    JOIN public.store_workflow_configs c ON c.restaurant_id=a.restaurant_id AND c.active_id::text=v_parts[4]
    JOIN public.store_workflow_releases r ON r.id=c.active_id,jsonb_array_elements(r.definition->'stations')s
    WHERE u.auth_id=auth.uid() AND u.is_active AND c.restaurant_id::text=v_parts[2] AND s->>'id'=v_parts[3] AND s->'user_ids' ? u.id::text);
  END IF;
  IF cardinality(v_parts) NOT IN (3, 4) OR v_parts[1] <> 'kds' THEN
    RETURN false;
  END IF;
  BEGIN
    v_store_id := v_parts[2]::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;
  v_station := v_parts[3];
  v_floor := CASE WHEN cardinality(v_parts) = 4 THEN v_parts[4] END;
  IF v_station NOT IN ('kitchen', 'tray', 'floor', 'control') THEN
    RETURN false;
  END IF;

  SELECT assignment.* INTO v_assignment
  FROM public.users user_row
  JOIN public.emergency_station_assignments assignment
    ON assignment.user_id = user_row.id
   AND assignment.restaurant_id = v_store_id
   AND assignment.is_active = true
  WHERE user_row.auth_id = auth.uid()
    AND user_row.is_active = true
  LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_station='kitchen' AND EXISTS(SELECT 1 FROM public.store_workflow_configs WHERE restaurant_id=v_store_id AND active_id IS NOT NULL) THEN RETURN false; END IF;
  IF v_station = 'control' THEN
    RETURN cardinality(v_parts) = 3;
  END IF;
  IF v_assignment.station_type <> v_station THEN RETURN false; END IF;
  IF v_station = 'floor' THEN
    RETURN cardinality(v_parts) = 4
      AND v_assignment.floor_label = v_floor;
  END IF;
  RETURN cardinality(v_parts) = 3;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_kds_bootstrap_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_config jsonb;
  v_snapshot jsonb;
  v_completed jsonb;
  v_timings jsonb;
  v_store_id uuid;
  v_mode text;
BEGIN
  v_config := public.get_kds_sync_config();
  v_snapshot := public.get_emergency_station_snapshot();
  v_completed := public.get_emergency_station_today_completed();
  v_timings := public.get_emergency_station_timings();
  v_store_id := NULLIF(v_config->>'restaurant_id', '')::uuid;
  IF v_store_id IS NOT NULL THEN
    v_mode := public.get_store_fulfillment_mode(v_store_id);
  END IF;
  IF v_snapshot->'operating_workflow'->>'active_id' IS NOT NULL AND v_snapshot->>'station_type'='kitchen' THEN v_completed:='[]';v_timings:='[]'; END IF;
  RETURN jsonb_build_object(
    'sync', v_config,
    'snapshot', v_snapshot,
    'completed_orders', COALESCE(v_completed, '[]'::jsonb),
    'timings', COALESCE(v_timings, '[]'::jsonb),
    'fulfillment_mode', COALESCE(v_mode, 'paperless')
  );
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_kds_changes_v2"("p_after_revision" bigint, "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_config jsonb;
  v_store_id uuid;
  v_station text;
  v_floor text;
  v_after bigint := GREATEST(COALESCE(p_after_revision, 0), 0);
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_current bigint := 0;
  v_earliest bigint;
  v_scanned bigint;
  v_changes jsonb := '[]'::jsonb;
BEGIN
  v_config := public.get_kds_sync_config();
  IF COALESCE((v_config->>'assigned')::boolean, false) = false THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED';
  END IF;
  v_store_id := (v_config->>'restaurant_id')::uuid;
  IF v_config->>'station_type'='kitchen' AND EXISTS(SELECT 1 FROM public.store_workflow_configs WHERE restaurant_id=v_store_id AND active_id IS NOT NULL) THEN RETURN jsonb_build_object('bootstrap_required',true,'has_more',false,'changes','[]'::jsonb); END IF;
  v_station := v_config->>'station_type';
  v_floor := v_config->>'floor_label';
  v_current := COALESCE((v_config->>'revision')::bigint, 0);
  SELECT min(revision) INTO v_earliest
  FROM public.kds_change_log
  WHERE restaurant_id = v_store_id;
  IF v_earliest IS NOT NULL AND v_after < v_earliest - 1 THEN
    RETURN jsonb_build_object(
      'bootstrap_required', true,
      'scanned_through_revision', v_after,
      'current_revision', v_current,
      'has_more', false,
      'changes', '[]'::jsonb
    );
  END IF;

  WITH revision_window AS (
    SELECT change.*
    FROM public.kds_change_log change
    WHERE change.restaurant_id = v_store_id
      AND change.revision > v_after
    ORDER BY change.revision
    LIMIT v_limit
  )
  SELECT
    COALESCE(max(change_row.revision), v_after),
    COALESCE(jsonb_agg(jsonb_build_object(
      'schema_version', 1,
      'restaurant_id', change_row.restaurant_id,
      'session_id', change_row.session_id,
      'revision', change_row.revision,
      'event_id', change_row.event_id,
      'event_type', change_row.event_type,
      'target_stations', change_row.target_stations,
      'target_floor_label', change_row.target_floor_label,
      'queue_id', change_row.queue_id,
      'order_id', change_row.order_id,
      'order_item_id', change_row.order_item_id,
      'payload', change_row.payload,
      'occurred_at', change_row.created_at
    ) ORDER BY change_row.revision) FILTER (
        WHERE 'control' = ANY(change_row.target_stations)
           OR (
             v_station = ANY(change_row.target_stations)
             AND (
               v_station <> 'floor'
               OR change_row.target_floor_label IS NULL
               OR change_row.target_floor_label = v_floor
             )
           )
      ), '[]'::jsonb)
  INTO v_scanned, v_changes
  FROM revision_window change_row;

  RETURN jsonb_build_object(
    'bootstrap_required', false,
    'scanned_through_revision', v_scanned,
    'current_revision', v_current,
    'has_more', v_scanned < v_current,
    'changes', v_changes
  );
END;
$$;


CREATE FUNCTION public.store_workflow_packaging_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE usr public.users%ROWTYPE; definition jsonb;
BEGIN
 SELECT * INTO usr FROM public.users WHERE auth_id=auth.uid() AND is_active;
 IF EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE user_id=usr.id AND restaurant_id=NEW.restaurant_id AND quiesced) THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_QUIESCED'; END IF;
 IF EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE user_id=usr.id AND restaurant_id=NEW.restaurant_id AND station_type='kitchen' AND is_active) THEN
  SELECT r.definition INTO definition FROM public.store_workflow_configs c JOIN public.store_workflow_releases r ON r.id=c.active_id WHERE c.restaurant_id=NEW.restaurant_id;
  IF definition IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(definition->'stations')s WHERE s->>'id'=coalesce(definition->>'packaging_station_id',definition->'default_path'->>0) AND s->'user_ids' ? usr.id::text) THEN RAISE EXCEPTION 'WORKFLOW_STATION_FORBIDDEN'; END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER workflow_packaging_guard BEFORE UPDATE ON public.leftover_packaging_requests FOR EACH ROW EXECUTE FUNCTION public.store_workflow_packaging_guard();
CREATE FUNCTION public.store_workflow_floor_device_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF current_setting('globos.cashier_item_mutation',true) IN ('on','repair') THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM public.store_workflow_devices d JOIN public.users u ON u.id=d.user_id WHERE u.auth_id=auth.uid() AND d.quiesced) AND EXISTS(SELECT 1 FROM new_workflow_progress n JOIN old_workflow_progress o USING(id) WHERE n.floor_served_quantity>o.floor_served_quantity) THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_QUIESCED'; END IF;
 RETURN NULL;
END;
$$;
CREATE TRIGGER workflow_floor_device_guard AFTER UPDATE ON public.emergency_floor_direct_items REFERENCING OLD TABLE AS old_workflow_progress NEW TABLE AS new_workflow_progress FOR EACH STATEMENT EXECUTE FUNCTION public.store_workflow_floor_device_guard();
REVOKE ALL ON FUNCTION public.store_workflow_packaging_guard(),public.store_workflow_floor_device_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.emergency_enqueue_push(p_event_id uuid, p_store_id uuid, p_order_id uuid, p_target_station text, p_floor_label text, p_stage text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_catalog'
AS $function$
  INSERT INTO public.emergency_push_deliveries (
    event_id, restaurant_id, device_id, push_token, station_type,
    floor_label, order_id, stage
  )
  SELECT
    p_event_id, p_store_id, device.id, device.token,
    assignment.station_type, assignment.floor_label, p_order_id, p_stage
  FROM public.emergency_web_push_devices device
  JOIN public.emergency_station_assignments assignment
    ON assignment.id = device.station_assignment_id
   AND assignment.restaurant_id = p_store_id
   AND assignment.is_active = true
  WHERE device.restaurant_id = p_store_id
    AND device.is_enabled = true
    AND assignment.station_type = p_target_station
    AND NOT (p_target_station='kitchen' AND p_stage='order_received' AND EXISTS(SELECT 1 FROM public.orders o WHERE o.id=p_order_id AND o.operating_release_id IS NOT NULL))
    AND (p_target_station <> 'floor' OR assignment.floor_label = p_floor_label)
    AND NOT (
      p_target_station = 'floor'
      AND EXISTS (
        SELECT 1 FROM public.orders order_row
        WHERE order_row.id = p_order_id
          AND (order_row.sales_channel = 'delivery'
            OR public.direct_order_is_pickup_pos_order(order_row.id, order_row.restaurant_id))
      )
    )
  ON CONFLICT (event_id, device_id) DO NOTHING;
$function$;


NOTIFY pgrst,'reload schema';
DO $verify$ BEGIN
 IF has_function_privilege('authenticated','public.store_workflow_notify(uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.store_preparation_ready_notify(uuid[])','EXECUTE')
 OR strpos(pg_get_functiondef('public.kds_can_access_topic(text)'::regprocedure),'workflow')=0
 OR strpos(pg_get_functiondef('public.get_emergency_station_snapshot()'::regprocedure),'operating_workflow')=0
 THEN RAISE EXCEPTION 'WORKFLOW_CLIENT_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
