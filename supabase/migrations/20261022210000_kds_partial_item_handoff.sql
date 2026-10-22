-- Partial handoffs use ready quantities; preparation may remain ahead of handoff.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $backup$
DECLARE definition text;
BEGIN
  IF to_regprocedure('public.kds_record_station_progress_before_partial(uuid,text,text,integer,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_PARTIAL_BACKUP_ALREADY_EXISTS';
  END IF;
  definition := pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
  EXECUTE replace(definition, 'FUNCTION public.kds_record_station_progress_v3(', 'FUNCTION public.kds_record_station_progress_before_partial(');
  REVOKE ALL ON FUNCTION public.kds_record_station_progress_before_partial(uuid,text,text,integer,uuid) FROM PUBLIC, anon, authenticated, service_role;
  IF to_regprocedure('public.kds_serve_ready_order_before_partial(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_PARTIAL_BACKUP_ALREADY_EXISTS';
  END IF;
  definition := pg_get_functiondef('public.kds_serve_ready_order_v3(uuid,uuid)'::regprocedure);
  EXECUTE replace(definition, 'FUNCTION public.kds_serve_ready_order_v3(', 'FUNCTION public.kds_serve_ready_order_before_partial(');
  REVOKE ALL ON FUNCTION public.kds_serve_ready_order_before_partial(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
  IF to_regprocedure('public.kds_apply_station_progress_before_partial(uuid,uuid,uuid,text,text,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_PARTIAL_BACKUP_ALREADY_EXISTS';
  END IF;
  definition := pg_get_functiondef('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
  EXECUTE replace(definition, 'FUNCTION public.kds_apply_station_progress_batch_v1(', 'FUNCTION public.kds_apply_station_progress_before_partial(');
  REVOKE ALL ON FUNCTION public.kds_apply_station_progress_before_partial(uuid,uuid,uuid,text,text,jsonb) FROM PUBLIC, anon, authenticated, service_role;
END;
$backup$;

DO $patch$
DECLARE definition text; old_text text; new_text text;
BEGIN
  definition := pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
  old_text := 'OR v_done <> v_started OR v_done < 0 OR v_done > v_required';
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text) <> 1 THEN
    RAISE EXCEPTION 'KDS_PARTIAL_PREDECESSOR_DRIFT';
  END IF;
  EXECUTE replace(definition, old_text,
    'OR v_done > v_started OR v_started < 0 OR v_started > v_required OR v_done < 0 OR v_done > v_required');

  definition := pg_get_functiondef('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
  old_text := $old$  IF p_action = 'tray_dispatched' AND EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(
        lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
      ), 0)::integer AS available
      FROM public.emergency_tray_ready_lots lot
      WHERE lot.source_kind = allocation.source_kind
        AND lot.source_id = allocation.item_id
    ) ready ON true
    WHERE ready.available < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;$old$;
  new_text := $new$  IF p_action = 'tray_dispatched' AND EXISTS (
    WITH allocations AS MATERIALIZED (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), ready AS (
      SELECT lot.source_kind, lot.source_id,
        sum(lot.ready_quantity - lot.handed_quantity - lot.voided_quantity) AS available
      FROM public.emergency_tray_ready_lots lot
      JOIN allocations allocation ON allocation.source_kind = lot.source_kind
        AND allocation.item_id = lot.source_id
      GROUP BY lot.source_kind, lot.source_id
    )
    SELECT 1 FROM allocations allocation
    LEFT JOIN ready ON ready.source_kind = allocation.source_kind
      AND ready.source_id = allocation.item_id
    WHERE COALESCE(ready.available, 0) < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;$new$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text) <> 1 THEN RAISE EXCEPTION 'KDS_PARTIAL_LOT_PREDECESSOR_DRIFT:tray_dispatched'; END IF;
  definition := replace(definition, old_text, new_text);
  old_text := $old$  IF p_action = 'floor_served' AND EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(
        lot.ready_quantity - lot.served_quantity - lot.voided_quantity
      ), 0)::integer AS available
      FROM public.emergency_floor_ready_lots lot
      WHERE lot.source_kind = allocation.source_kind
        AND lot.source_id = allocation.item_id
    ) ready ON true
    WHERE ready.available < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;$old$;
  new_text := $new$  IF p_action = 'floor_served' AND EXISTS (
    WITH allocations AS MATERIALIZED (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), ready AS (
      SELECT lot.source_kind, lot.source_id,
        sum(lot.ready_quantity - lot.served_quantity - lot.voided_quantity) AS available
      FROM public.emergency_floor_ready_lots lot
      JOIN allocations allocation ON allocation.source_kind = lot.source_kind
        AND allocation.item_id = lot.source_id
      GROUP BY lot.source_kind, lot.source_id
    )
    SELECT 1 FROM allocations allocation
    LEFT JOIN ready ON ready.source_kind = allocation.source_kind
      AND ready.source_id = allocation.item_id
    WHERE COALESCE(ready.available, 0) < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;$new$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text) <> 1 THEN RAISE EXCEPTION 'KDS_PARTIAL_LOT_PREDECESSOR_DRIFT:floor_served'; END IF;
  definition := replace(definition, old_text, new_text);
  EXECUTE definition;
END;
$patch$;

CREATE OR REPLACE FUNCTION public.kds_serve_ready_order_v3(
  p_queue_id uuid, p_action_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_existing public.emergency_fulfillment_actions%ROWTYPE;
  v_allocations jsonb;
  v_count integer;
  v_quantity integer;
BEGIN
  IF p_queue_id IS NULL OR p_action_id IS NULL THEN
    RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users WHERE auth_id = auth.uid() AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id AND is_active;
  IF NOT FOUND OR v_assignment.station_type <> 'floor' THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;
  SELECT queue.* INTO v_queue FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id AND session.status = 'active'
  WHERE queue.id = p_queue_id FOR UPDATE OF queue;
  IF NOT FOUND OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR NOT (v_queue.floor_label = ANY(public.store_assignment_area_codes_v1(v_assignment)))
     OR v_queue.workflow_version <> 2 THEN
    RAISE EXCEPTION 'EMERGENCY_QUEUE_UNAVAILABLE';
  END IF;
  SELECT * INTO v_existing FROM public.emergency_fulfillment_actions WHERE action_id = p_action_id;
  IF FOUND THEN
    IF v_existing.queue_id <> p_queue_id OR v_existing.station_type <> 'floor'
       OR v_existing.action_kind <> 'complete' THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN jsonb_build_object('action_id', p_action_id, 'deduplicated', true, 'changed_quantity', 0);
  END IF;

  -- One bounded set of food lines. Floor-direct drinks retain their separate
  -- item actions, just as in the preceding serve-ready-order contract.
  WITH lines AS (
    SELECT item.id AS item_id, item.queue_id, 'base'::text AS source_kind,
      item.tray_dispatched_quantity - item.floor_served_quantity AS quantity
    FROM public.emergency_fulfillment_items item
    WHERE item.queue_id = p_queue_id AND NOT item.is_cancelled AND NOT item.needs_review
      AND item.tray_dispatched_quantity > item.floor_served_quantity
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id AND component.order_item_id = item.order_item_id
          AND NOT component.is_cancelled
      )
    UNION ALL
    SELECT component.id, component.queue_id, 'combo_component',
      component.tray_dispatched_quantity - component.floor_served_quantity
    FROM public.emergency_combo_component_items component
    WHERE component.queue_id = p_queue_id AND NOT component.is_cancelled AND NOT component.needs_review
      AND component.tray_dispatched_quantity > component.floor_served_quantity
  ), bounded AS (
    SELECT * FROM lines ORDER BY source_kind, item_id LIMIT 1001
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(bounded) ORDER BY source_kind, item_id), '[]'::jsonb),
    count(*)::integer, COALESCE(sum(quantity), 0)::integer
  INTO v_allocations, v_count, v_quantity FROM bounded;
  IF v_count > 1000 OR v_quantity > 1000 THEN RAISE EXCEPTION 'KDS_BATCH_INPUT_INVALID'; END IF;

  INSERT INTO public.emergency_fulfillment_actions(
    action_id, session_id, restaurant_id, queue_id, order_id,
    station_type, floor_label, action_kind, stage, actor_user_id
  ) VALUES (
    p_action_id, v_queue.session_id, v_queue.restaurant_id, v_queue.id, v_queue.order_id,
    'floor', v_queue.floor_label, 'complete', 'floor_served', v_user.id
  );
  IF v_count > 0 THEN
    PERFORM public.kds_apply_station_progress_batch_v1(
      p_action_id, v_assignment.restaurant_id, v_user.id, 'floor_served',
      v_queue.floor_label, v_allocations
    );
    -- Each event carries batch_request_id = p_action_id. Do not attach these
    -- workflow-v2 lots to the legacy whole-order undo ledger, whose quantity
    -- reversal does not restore ready lots or component projections.
  END IF;
  RETURN jsonb_build_object('action_id', p_action_id, 'deduplicated', false,
    'changed_quantity', v_quantity);
END;
$$;
REVOKE ALL ON FUNCTION public.kds_serve_ready_order_v3(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_serve_ready_order_v3(uuid,uuid) TO authenticated;

DO $verify$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
  IF position('v_done <> v_started' IN definition) > 0
     OR position('v_started > v_required' IN definition) = 0 THEN
    RAISE EXCEPTION 'KDS_PARTIAL_CHAIN_VERIFY_FAILED';
  END IF;
  definition := pg_get_functiondef('public.kds_serve_ready_order_v3(uuid,uuid)'::regprocedure);
  IF definition ~* '\m(loop|foreach)\M'
     OR position('kds_record_station_progress_v3(' IN definition) > 0
     OR position('kds_apply_station_progress_batch_v1(' IN definition) = 0 THEN
    RAISE EXCEPTION 'KDS_PARTIAL_SET_VERIFY_FAILED';
  END IF;
END;
$verify$;
COMMIT;
