-- JeonGabok cooking start must never publish food to a floor.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- A separate preparation command avoids the legacy start -> done alias.
-- It changes only preparation quantity, never ready lots or service progress.
CREATE FUNCTION public.kds_record_direct_preparation_v1(
 p_item_id uuid,p_source_kind text,p_delta integer,p_event_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor public.users%ROWTYPE; line record; queue public.emergency_order_queue%ROWTYPE;
 previous public.emergency_fulfillment_events%ROWTYPE; next_started integer;
 parent_id uuid; parent_started integer; response jsonb;
BEGIN
 IF p_item_id IS NULL OR p_event_id IS NULL OR p_delta IS NULL OR p_delta NOT IN (-1,1)
  OR p_source_kind IS NULL OR p_source_kind NOT IN ('base','combo_component') THEN
  RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
 END IF;
 SELECT u.* INTO actor FROM public.users u JOIN public.emergency_station_assignments a
  ON a.user_id=u.id AND a.restaurant_id=u.restaurant_id AND a.is_active AND a.station_type='kitchen'
 WHERE u.auth_id=auth.uid() AND u.is_active AND public.kds_is_direct_floor_store(u.restaurant_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(actor.restaurant_id::text||':kitchen-batch',0));
 IF p_source_kind='base' THEN
  SELECT * INTO line FROM public.emergency_fulfillment_items WHERE id=p_item_id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM public.emergency_combo_component_items c WHERE c.session_id=line.session_id
   AND c.order_item_id=line.order_item_id AND NOT c.is_cancelled) THEN RAISE EXCEPTION 'KDS_COMBO_PARENT_READ_ONLY'; END IF;
 ELSE
  SELECT * INTO line FROM public.emergency_combo_component_items WHERE id=p_item_id FOR UPDATE;
 END IF;
 IF line.id IS NULL OR line.restaurant_id<>actor.restaurant_id OR line.is_cancelled OR line.needs_review THEN
  RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE'; END IF;
 SELECT q.* INTO queue FROM public.emergency_order_queue q
 JOIN public.emergency_fulfillment_sessions s ON s.id=q.session_id AND s.status='active'
 WHERE q.id=line.queue_id AND q.kitchen_direct_to_floor FOR UPDATE OF q;
 IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;
 SELECT * INTO previous FROM public.emergency_fulfillment_events WHERE event_id=p_event_id;
 IF FOUND THEN
  IF previous.restaurant_id<>actor.restaurant_id OR previous.stage<>'kitchen_started' OR previous.delta<>p_delta
   OR previous.details->>'source_id' IS DISTINCT FROM p_item_id::text
   OR previous.details->>'source_kind' IS DISTINCT FROM p_source_kind THEN RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT'; END IF;
  RETURN previous.details->'response'||jsonb_build_object('event_id',p_event_id,'deduplicated',true);
 END IF;
 next_started:=line.kitchen_started_quantity+p_delta;
 IF next_started<line.kitchen_done_quantity OR next_started>line.ordered_quantity-line.excused_quantity THEN
  RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION'; END IF;
 IF p_source_kind='base' THEN
  UPDATE public.emergency_fulfillment_items SET kitchen_started_quantity=next_started,updated_at=now() WHERE id=line.id;
 ELSE
  UPDATE public.emergency_combo_component_items SET kitchen_started_quantity=next_started,updated_at=now() WHERE id=line.id;
  SELECT id INTO parent_id FROM public.emergency_fulfillment_items p
   WHERE p.session_id=line.session_id AND p.order_item_id=line.order_item_id FOR UPDATE;
  SELECT COALESCE(min(c.kitchen_started_quantity*p.ordered_quantity/nullif(c.ordered_quantity,0)),0)::integer
   INTO parent_started FROM public.emergency_combo_component_items c JOIN public.emergency_fulfillment_items p ON p.id=parent_id
   WHERE c.session_id=line.session_id AND c.order_item_id=line.order_item_id AND NOT c.is_cancelled;
  UPDATE public.emergency_fulfillment_items SET kitchen_started_quantity=parent_started,updated_at=now() WHERE id=parent_id;
 END IF;
 response:=jsonb_build_object('kitchen_started_quantity',next_started,'kitchen_done_quantity',line.kitchen_done_quantity,
  'tray_received_quantity',line.tray_received_quantity,'tray_dispatched_quantity',line.tray_dispatched_quantity,
  'floor_served_quantity',line.floor_served_quantity);
 INSERT INTO public.emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,combo_component_item_id,stage,delta,actor_user_id,details)
 VALUES(p_event_id,line.session_id,line.restaurant_id,line.order_id,line.order_item_id,
  CASE WHEN p_source_kind='combo_component' THEN line.id END,'kitchen_started',p_delta,actor.id,
  jsonb_build_object('workflow_action','kitchen_started','source_kind',p_source_kind,'source_id',line.id,'response',response));
 RETURN response||jsonb_build_object('event_id',p_event_id,'deduplicated',false);
END;
$$;
REVOKE ALL ON FUNCTION public.kds_record_direct_preparation_v1(uuid,text,integer,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION pg_temp.explicit_handoff_patch(signature text, old_text text, new_text text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef(to_regprocedure(signature));
  IF definition IS NULL OR
    (length(definition)-length(replace(definition,old_text,'')))/length(old_text) <> 1 THEN
    RAISE EXCEPTION 'EXPLICIT_HANDOFF_PREDECESSOR_DRIFT:%',signature;
  END IF;
  EXECUTE replace(definition,old_text,new_text);
END;
$$;

SELECT pg_temp.explicit_handoff_patch(
  'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)',
  $old$IF p_action IN ('kitchen_done', 'kitchen_started') AND EXISTS ($old$,
  $new$IF p_action = 'kitchen_started' AND EXISTS (
    SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
      AND public.kds_is_direct_floor_store(u.restaurant_id)
  ) THEN RETURN public.kds_record_direct_preparation_v1(p_item_id, p_source_kind, p_delta, p_event_id); END IF;
  IF p_action = 'kitchen_done' AND EXISTS ($new$);

-- The same locked batch can hand off both previously started and unstarted
-- quantities. Keep the old calculation for every other store. No row loops.
SELECT pg_temp.explicit_handoff_patch(
  'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$THEN item.kitchen_started_quantity + allocation.quantity$old$,
  $new$THEN CASE WHEN v_direct THEN greatest(item.kitchen_started_quantity,
        item.kitchen_done_quantity + allocation.quantity)
        ELSE item.kitchen_started_quantity + allocation.quantity END$new$);
SELECT pg_temp.explicit_handoff_patch(
  'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$THEN component.kitchen_started_quantity + allocation.quantity$old$,
  $new$THEN CASE WHEN v_direct THEN greatest(component.kitchen_started_quantity,
        component.kitchen_done_quantity + allocation.quantity)
        ELSE component.kitchen_started_quantity + allocation.quantity END$new$);
SELECT pg_temp.explicit_handoff_patch(
  'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$THEN parent_values.stage_quantity ELSE parent.kitchen_started_quantity END$old$,
  $new$THEN CASE WHEN v_direct THEN greatest(parent.kitchen_started_quantity,
        parent_values.stage_quantity) ELSE parent_values.stage_quantity END
        ELSE parent.kitchen_started_quantity END$new$);

DO $$ DECLARE definition text;
BEGIN
  definition := pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
  IF definition LIKE '%IF p_action IN (''kitchen_done'', ''kitchen_started'')%'
    OR definition NOT LIKE '%IF p_action = ''kitchen_done'' AND EXISTS (%'
    OR definition NOT LIKE '%RETURN public.kds_record_direct_preparation_v1(%'
    OR has_function_privilege('anon','public.kds_record_direct_preparation_v1(uuid,text,integer,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'EXPLICIT_HANDOFF_START_GUARD_FAILED';
  END IF;
  definition := pg_get_functiondef('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
  IF definition NOT LIKE '%greatest(item.kitchen_started_quantity,%'
    OR definition NOT LIKE '%greatest(component.kitchen_started_quantity,%'
    OR definition NOT LIKE '%greatest(parent.kitchen_started_quantity,%'
    OR definition ~* '\m(loop|foreach)\M' THEN
    RAISE EXCEPTION 'EXPLICIT_HANDOFF_BATCH_GUARD_FAILED';
  END IF;
END;
$$;
COMMIT;
