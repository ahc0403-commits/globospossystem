-- Owner decision: JeonGabok has no checker. Other stores retain their workflow.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Compare the small operational identity/configuration sets inside the same
-- atomic cutover. No other store's account or settings may change here.
CREATE TEMP TABLE kds_other_store_before ON COMMIT DROP AS
SELECT 'users' AS kind, md5(COALESCE(jsonb_agg(to_jsonb(u) ORDER BY u.id)::text, '[]')) AS digest
FROM public.users u WHERE u.restaurant_id <> '273b057e-3b69-46e3-93c1-6194c2802849'
UNION ALL SELECT 'requirements', md5(COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id)::text, '[]'))
FROM public.store_fixed_account_requirements q WHERE q.store_id <> '273b057e-3b69-46e3-93c1-6194c2802849'
UNION ALL SELECT 'assignments', md5(COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text, '[]'))
FROM public.emergency_station_assignments a WHERE a.restaurant_id <> '273b057e-3b69-46e3-93c1-6194c2802849'
UNION ALL SELECT 'settings', md5(COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.restaurant_id)::text, '[]'))
FROM public.restaurant_settings s WHERE s.restaurant_id <> '273b057e-3b69-46e3-93c1-6194c2802849';

CREATE FUNCTION public.kds_is_direct_floor_store(p_store_id uuid)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog AS $$
  SELECT COALESCE(p_store_id = '273b057e-3b69-46e3-93c1-6194c2802849'::uuid, false);
$$;
COMMENT ON FUNCTION public.kds_is_direct_floor_store(uuid) IS
  '2026-10-20 owner decision. Immutable store allow-list; changing it requires a reviewed migration.';
REVOKE ALL ON FUNCTION public.kds_is_direct_floor_store(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_is_direct_floor_store(uuid) TO authenticated, service_role;

ALTER TABLE public.emergency_order_queue
  ADD COLUMN kitchen_direct_to_floor boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT kds_direct_floor_store_scope CHECK (
    NOT kitchen_direct_to_floor OR public.kds_is_direct_floor_store(restaurant_id)
  );
CREATE FUNCTION public.kds_assign_direct_floor_workflow()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  NEW.kitchen_direct_to_floor := public.kds_is_direct_floor_store(NEW.restaurant_id);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_assign_direct_floor_workflow() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER kds_assign_direct_floor_workflow
BEFORE INSERT ON public.emergency_order_queue
FOR EACH ROW EXECUTE FUNCTION public.kds_assign_direct_floor_workflow();

-- Do not reinterpret an in-flight or historical service record. The cutover
-- fails atomically if new unfinished work arrived after the release preflight.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.restaurants
    WHERE id = '273b057e-3b69-46e3-93c1-6194c2802849' AND is_active
      AND name = 'JeonGabok Binh Thanh') THEN
    RAISE EXCEPTION 'JEONGABOK_STORE_IDENTITY_CHANGED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.emergency_order_queue q
    JOIN public.emergency_fulfillment_sessions s ON s.id = q.session_id AND s.status = 'active'
    JOIN public.emergency_fulfillment_items i ON i.queue_id = q.id
    WHERE public.kds_is_direct_floor_store(q.restaurant_id) AND NOT i.is_cancelled
      AND i.floor_served_quantity < i.ordered_quantity - i.excused_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_floor_direct_items i
    JOIN public.emergency_fulfillment_sessions s ON s.id = i.session_id AND s.status = 'active'
    WHERE public.kds_is_direct_floor_store(i.restaurant_id) AND NOT i.is_cancelled
      AND i.floor_served_quantity < i.ordered_quantity - i.excused_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.leftover_packaging_requests r
    WHERE public.kds_is_direct_floor_store(r.restaurant_id)
      AND r.status NOT IN ('completed', 'cancelled')
  ) THEN RAISE EXCEPTION 'JEONGABOK_CUTOVER_REQUIRES_DRAINED_ORDERS'; END IF;
END;
$$;
UPDATE public.emergency_order_queue q SET kitchen_direct_to_floor = true
FROM public.emergency_fulfillment_sessions s
WHERE s.id = q.session_id AND s.status = 'active'
  AND public.kds_is_direct_floor_store(q.restaurant_id);

-- Patch only verified anchors in the effective production definitions. Every
-- behavioral branch is guarded by the immutable store allow-list.
CREATE FUNCTION pg_temp.kds_direct_patch(signature text, old_text text, new_text text,
  expected_count integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef(to_regprocedure(signature));
  IF definition IS NULL OR old_text = '' OR
    (length(definition) - length(replace(definition, old_text, ''))) / length(old_text) <> expected_count THEN
    RAISE EXCEPTION 'KDS_DIRECT_PREDECESSOR_DRIFT:%', signature;
  END IF;
  EXECUTE replace(definition, old_text, new_text);
END;
$$;

-- Preserve the existing set-based kernel, its bounds, locks, FIFO and request
-- idempotency. Direct kitchens publish floor lots instead of pending tray lots.
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$  v_allocation_count integer;$old$,
  $new$  v_direct boolean := public.kds_is_direct_floor_store(p_restaurant_id);
  v_allocation_count integer;$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$IF p_action = 'kitchen_done' AND v_workflow_two_quantity > 0 THEN$old$,
  $new$IF p_action = 'kitchen_done' AND NOT v_direct AND v_workflow_two_quantity > 0 THEN$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$  IF p_action = 'tray_dispatched' THEN
    WITH allocations AS ($old$,
  $new$  IF p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done') THEN
    WITH allocations AS ($new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$    FROM ranked;
  ELSIF p_action = 'floor_served' THEN$old$,
  $new$    FROM ranked
    WHERE NOT v_direct OR (NOT EXISTS (
      SELECT 1 FROM public.orders o WHERE o.id = ranked.order_id AND o.sales_channel = 'delivery'
    ) AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials f
      JOIN public.direct_order_requests r ON r.id = f.request_id AND r.fulfillment_type = 'pickup'
      WHERE f.order_id = ranked.order_id AND f.restaurant_id = p_restaurant_id));
  ELSIF p_action = 'floor_served' THEN$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$tray_received_quantity = CASE WHEN p_action = 'tray_dispatched'$old$,
  $new$tray_received_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')$new$, 3);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched'$old$,
  $new$tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')$new$, 3);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$'workflow_action', p_action,$old$,
  $new$'kitchen_direct_to_floor', v_direct, 'workflow_action', p_action,$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$WHEN 'kitchen_done' THEN 'tray' ELSE 'floor' END$old$,
  $new$WHEN 'kitchen_done' THEN CASE WHEN v_direct THEN 'floor' ELSE 'tray' END ELSE 'floor' END$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$AND event_rows.channel = 'delivery')$old$,
  $new$AND (event_rows.channel = 'delivery' OR (v_direct AND EXISTS (
    SELECT 1 FROM public.direct_order_financials f JOIN public.direct_order_requests r
      ON r.id = f.request_id AND r.fulfillment_type = 'pickup'
    WHERE f.order_id = event_rows.order_id AND f.restaurant_id = p_restaurant_id))))$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$md5(p_request_id::text || ':tray_dispatched:' || ranked.source_kind$old$,
  $new$md5(p_request_id::text || ':' || p_action || ':' || ranked.source_kind$new$);

SELECT pg_temp.kds_direct_patch('public.kds_capture_fulfillment_event()',
  $old$  PERFORM public.kds_append_change($old$,
  $new$  v_payload := v_payload || jsonb_build_object('no_floor_delivery', v_delivery);
  PERFORM public.kds_append_change($new$);

-- Update direct pickup/delivery preparation once for the whole selected set.
-- Readiness is never courier dispatch or customer pickup.
SELECT pg_temp.kds_direct_patch('public.sync_direct_delivery_ticket_from_kds()',
  $old$BEGIN
$old$,
  $new$BEGIN
  IF public.kds_is_direct_floor_store(NEW.restaurant_id) AND NEW.stage = 'kitchen_done' THEN RETURN NEW; END IF;
$new$);
SELECT pg_temp.kds_direct_patch('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
  $old$  -- Push fan-out is also one set operation.$old$,
  $new$  IF v_direct AND p_action = 'kitchen_done' THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(item_id uuid, queue_id uuid, source_kind text, quantity integer)
    ), affected AS MATERIALIZED (
      SELECT i.order_id FROM allocations a JOIN public.emergency_fulfillment_items i
        ON i.id = a.item_id AND a.source_kind = 'base'
      UNION
      SELECT i.order_id FROM allocations a JOIN public.emergency_combo_component_items i
        ON i.id = a.item_id AND a.source_kind = 'combo_component'
    ), readiness AS (
      SELECT t.id, bool_and(i.is_cancelled OR i.kitchen_done_quantity >= i.ordered_quantity - i.excused_quantity) AS ready
      FROM affected a JOIN public.direct_order_financials f ON f.order_id = a.order_id AND f.restaurant_id = p_restaurant_id
      JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id = f.request_id
      JOIN public.emergency_fulfillment_items i ON i.order_id = a.order_id
      WHERE t.status IN ('pending', 'preparing', 'ready')
      GROUP BY t.id
    )
    UPDATE public.direct_delivery_fulfillment_tickets t
    SET status = CASE WHEN r.ready THEN 'ready' ELSE 'preparing' END,
      version = t.version + 1, accepted_at = COALESCE(t.accepted_at, now()),
      ready_at = CASE WHEN r.ready THEN COALESCE(t.ready_at, now()) ELSE NULL END, updated_at = now()
    FROM readiness r WHERE t.id = r.id
      AND t.status IS DISTINCT FROM CASE WHEN r.ready THEN 'ready' ELSE 'preparing' END;
  END IF;

  -- Push fan-out is also one set operation.$new$);

SELECT pg_temp.kds_direct_patch('public.get_emergency_station_timings()',
  $old$WHEN 'floor' THEN 'tray_dispatched'$old$,
  $new$WHEN 'floor' THEN CASE WHEN public.kds_is_direct_floor_store(queue.restaurant_id) THEN 'kitchen_done' ELSE 'tray_dispatched' END$new$);
SELECT pg_temp.kds_direct_patch('public.emergency_add_order_batch_timings(jsonb)',
  $old$event.stage = 'tray_dispatched'$old$,
  $new$(event.stage = 'tray_dispatched' OR (public.kds_is_direct_floor_store(event.restaurant_id) AND event.stage = 'kitchen_done'))$new$, 2);

-- The physical kitchen ticket must not create a checker copy either.
SELECT pg_temp.kds_direct_patch('public.enqueue_tray_copy_for_kitchen_job()',
 $old$BEGIN
$old$,$new$BEGIN
  IF public.kds_is_direct_floor_store(NEW.restaurant_id) THEN RETURN NEW; END IF;
$new$);

-- Retire legacy whole-order mutations for this store; their old quantity-only
-- semantics cannot consume the floor-ready lots. Current clients use batches.
SELECT pg_temp.kds_direct_patch('public.emergency_complete_order_stage(uuid,uuid)',
  $old$BEGIN
$old$,
  $new$BEGIN
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
    AND public.kds_is_direct_floor_store(u.restaurant_id)) THEN
    RAISE EXCEPTION 'KDS_DIRECT_USE_ITEM_PROGRESS';
  END IF;
$new$);
SELECT pg_temp.kds_direct_patch('public.emergency_revert_order_action(uuid,uuid,uuid)',
  $old$BEGIN
$old$,
  $new$BEGIN
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
    AND public.kds_is_direct_floor_store(u.restaurant_id)) THEN
    RAISE EXCEPTION 'KDS_DIRECT_USE_ITEM_PROGRESS';
  END IF;
$new$);

-- Completion timing, QR progress and old read contracts retain the quantity
-- projections; the actor/event remains the kitchen, never a synthetic checker.
SELECT pg_temp.kds_direct_patch('public.emergency_floor_label(uuid,text,text)',
  $old$  SELECT CASE$old$,
  $new$  SELECT CASE
    WHEN public.kds_is_direct_floor_store(p_store_id)
      AND upper(btrim(p_floor_label)) IN ('1F', '2F', '3F') THEN upper(btrim(p_floor_label))$new$);

-- The last writer of change-log targeting always removes checker fan-out,
-- including old clients, catch-up and changes rewritten by workflow triggers.
CREATE FUNCTION public.kds_direct_filter_targets()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF NOT public.kds_is_direct_floor_store(NEW.restaurant_id) THEN RETURN NEW; END IF;
  NEW.target_stations := array_remove(NEW.target_stations, 'tray');
  IF NEW.payload->>'stage' IN ('kitchen_done', 'kitchen_started')
    AND COALESCE((NEW.payload->>'no_floor_delivery')::boolean, false) = false THEN
    NEW.target_stations := ARRAY['kitchen', 'floor'];
  ELSIF NEW.event_type = 'leftover_changed' THEN
    NEW.target_stations := ARRAY['kitchen', 'floor'];
  END IF;
  IF COALESCE(cardinality(NEW.target_stations), 0) = 0 THEN
    NEW.target_stations := ARRAY['kitchen'];
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_direct_filter_targets() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER kds_direct_filter_targets BEFORE INSERT OR UPDATE ON public.kds_change_log
FOR EACH ROW EXECUTE FUNCTION public.kds_direct_filter_targets();

-- Realtime caches topic authorization until a token is refreshed. Never send
-- direct-store invalidations on the old shared control topic, even for a
-- checker connection established before account retirement.
SELECT pg_temp.kds_direct_patch('public.kds_broadcast_change()',
  $old$  FOREACH v_station IN ARRAY v_change.target_stations LOOP$old$,
  $new$  IF public.kds_is_direct_floor_store(v_change.restaurant_id) THEN
    IF 'control' = ANY(v_change.target_stations) THEN
      v_change.target_stations := ARRAY['kitchen', 'floor'];
    END IF;
    FOREACH v_station IN ARRAY v_change.target_stations LOOP
      IF v_station = 'floor' AND v_change.target_floor_label IS NULL THEN
        PERFORM realtime.send(public.kds_change_envelope(v_change), 'kds_change',
          'kds:' || v_change.restaurant_id::text || ':floor:' || f, true)
        FROM unnest(ARRAY['1F','2F','3F']) f;
      ELSIF v_station IN ('kitchen', 'floor') THEN
        PERFORM realtime.send(public.kds_change_envelope(v_change), 'kds_change',
          'kds:' || v_change.restaurant_id::text || ':' || v_station ||
          CASE WHEN v_station = 'floor' THEN ':' || v_change.target_floor_label ELSE '' END, true);
      END IF;
    END LOOP;
    RETURN NEW;
  END IF;
  FOREACH v_station IN ARRAY v_change.target_stations LOOP$new$);

-- A disabled station is also rejected by bootstrap, ticket lookup, catch-up
-- and private broadcast RLS. Protect against provisioning reactivation.
CREATE FUNCTION public.kds_retire_direct_checker()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF TG_TABLE_NAME = 'users' THEN
    IF public.kds_is_direct_floor_store(NEW.restaurant_id)
      AND NEW.fixed_account_code ~ '_(tray1|tray)$' AND NEW.is_active THEN
      RAISE EXCEPTION 'JEONGABOK_CHECKER_RETIRED';
    END IF;
  ELSIF TG_TABLE_NAME = 'store_fixed_account_requirements' THEN
    IF public.kds_is_direct_floor_store(NEW.store_id) AND NEW.account_code ~ '_(tray1|tray)$' THEN
      NEW.is_active := false;
    END IF;
  ELSIF public.kds_is_direct_floor_store(NEW.restaurant_id) AND NEW.station_type = 'tray' THEN
    NEW.is_active := false;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_retire_direct_checker() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER kds_retire_direct_checker BEFORE INSERT OR UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.kds_retire_direct_checker();
CREATE TRIGGER kds_retire_direct_checker BEFORE INSERT OR UPDATE ON public.store_fixed_account_requirements
FOR EACH ROW EXECUTE FUNCTION public.kds_retire_direct_checker();
CREATE TRIGGER kds_retire_direct_checker BEFORE INSERT OR UPDATE ON public.emergency_station_assignments
FOR EACH ROW EXECUTE FUNCTION public.kds_retire_direct_checker();

UPDATE public.store_fixed_account_requirements SET is_active = false, updated_at = now()
WHERE public.kds_is_direct_floor_store(store_id) AND account_code ~ '_(tray1|tray)$';
UPDATE public.users SET is_active = false
WHERE public.kds_is_direct_floor_store(restaurant_id) AND fixed_account_code ~ '_(tray1|tray)$';
UPDATE public.user_store_access a SET is_active = false, updated_at = now()
FROM public.users u WHERE u.id = a.user_id
  AND public.kds_is_direct_floor_store(u.restaurant_id) AND u.fixed_account_code ~ '_(tray1|tray)$';
UPDATE public.emergency_station_assignments SET is_active = false, updated_at = now()
WHERE public.kds_is_direct_floor_store(restaurant_id) AND station_type = 'tray';
UPDATE public.emergency_web_push_devices d SET is_enabled = false, updated_at = now()
FROM public.emergency_station_assignments a WHERE a.id = d.station_assignment_id
  AND public.kds_is_direct_floor_store(a.restaurant_id) AND a.station_type = 'tray';
UPDATE public.emergency_push_deliveries SET status = 'cancelled', updated_at = now()
WHERE public.kds_is_direct_floor_store(restaurant_id) AND station_type = 'tray'
  AND status IN ('pending', 'sending', 'failed');
UPDATE auth.users a SET banned_until = now() + interval '100 years', updated_at = now()
FROM public.users u WHERE u.auth_id = a.id
  AND public.kds_is_direct_floor_store(u.restaurant_id) AND u.fixed_account_code ~ '_(tray1|tray)$';
INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
SELECT NULL,'jeongabok_checker_retired','users',u.id,jsonb_build_object(
  'source','20261020090000_jeongabok_kitchen_floor','restaurant_id',u.restaurant_id,
  'account_code',u.fixed_account_code,'kitchen_direct_to_floor',true,'owner_approved_on','2026-10-20')
FROM public.users u WHERE public.kds_is_direct_floor_store(u.restaurant_id)
  AND u.fixed_account_code ~ '_(tray1|tray)$';

-- Old access tokens cannot continue receiving legacy table subscriptions after
-- the profile is disabled. The active-user subquery is an uncorrelated initplan.
DO $$
DECLARE relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY['emergency_order_queue', 'emergency_fulfillment_items',
    'emergency_combo_component_items', 'emergency_fulfillment_events', 'emergency_fulfillment_actions',
    'emergency_floor_direct_items', 'emergency_floor_ready_lots', 'emergency_tray_ready_lots',
    'leftover_packaging_requests', 'orders', 'order_items', 'kds_change_log'] LOOP
    EXECUTE format('CREATE POLICY kds_direct_active_identity ON public.%I AS RESTRICTIVE
      FOR SELECT TO authenticated USING (NOT public.kds_is_direct_floor_store(restaurant_id)
        OR (SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active)))', relation_name);
  END LOOP;
END;
$$;

CREATE FUNCTION public.kds_record_direct_kitchen_v1(
  p_item_id uuid, p_source_kind text, p_delta integer, p_event_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE
  actor public.users%ROWTYPE;
  line record;
  queue public.emergency_order_queue%ROWTYPE;
  previous public.emergency_fulfillment_events%ROWTYPE;
  lot public.emergency_floor_ready_lots%ROWTYPE;
  result jsonb;
  response jsonb;
  parent_id uuid;
  parent_done integer;
BEGIN
  IF p_item_id IS NULL OR p_event_id IS NULL OR p_delta IS NULL OR p_delta NOT IN (-1, 1)
    OR p_source_kind IS NULL OR p_source_kind NOT IN ('base', 'combo_component') THEN
    RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
  END IF;
  SELECT u.* INTO actor FROM public.users u
  JOIN public.emergency_station_assignments a ON a.user_id = u.id
    AND a.restaurant_id = u.restaurant_id AND a.is_active AND a.station_type = 'kitchen'
  WHERE u.auth_id = auth.uid() AND u.is_active
    AND public.kds_is_direct_floor_store(u.restaurant_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor.restaurant_id::text || ':kitchen-batch', 0));
  IF p_source_kind = 'base' THEN
    SELECT * INTO line FROM public.emergency_fulfillment_items WHERE id = p_item_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.emergency_combo_component_items c
      WHERE c.session_id = line.session_id AND c.order_item_id = line.order_item_id AND NOT c.is_cancelled)
      THEN RAISE EXCEPTION 'KDS_COMBO_PARENT_READ_ONLY'; END IF;
  ELSE
    SELECT * INTO line FROM public.emergency_combo_component_items WHERE id = p_item_id FOR UPDATE;
  END IF;
  IF line.id IS NULL OR line.restaurant_id <> actor.restaurant_id OR line.is_cancelled OR line.needs_review THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  SELECT q.* INTO queue FROM public.emergency_order_queue q
  JOIN public.emergency_fulfillment_sessions s ON s.id = q.session_id AND s.status = 'active'
  WHERE q.id = line.queue_id AND q.kitchen_direct_to_floor FOR UPDATE OF q;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;
  IF EXISTS (SELECT 1 FROM public.direct_order_financials f
    JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id = f.request_id
    WHERE f.order_id = line.order_id AND t.status IN ('dispatched', 'delivered', 'completed', 'cancelled')) THEN
    RAISE EXCEPTION 'KDS_DIRECT_HANDOFF_FINALIZED';
  END IF;

  SELECT * INTO previous FROM public.emergency_fulfillment_events WHERE event_id = p_event_id;
  IF FOUND THEN
    IF p_delta <> -1 OR previous.restaurant_id <> actor.restaurant_id OR previous.delta <> -1
      OR previous.details->>'source_id' IS DISTINCT FROM p_item_id::text
      OR previous.details->>'source_kind' IS DISTINCT FROM p_source_kind THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN previous.details->'response' || jsonb_build_object('event_id', p_event_id, 'deduplicated', true);
  END IF;
  IF p_delta = 1 THEN
    result := public.kds_complete_kitchen_batch_v1(p_event_id, jsonb_build_array(jsonb_build_object(
      'item_id', p_item_id, 'queue_id', queue.id, 'source_kind', p_source_kind, 'quantity', 1
    )));
    SELECT e.details->'response' INTO response FROM public.emergency_fulfillment_events e
    WHERE e.event_id = (result->'event_ids'->>0)::uuid;
    RETURN response || jsonb_build_object('event_id', p_event_id, 'deduplicated', result->'deduplicated');
  END IF;
  IF EXISTS (SELECT 1 FROM public.emergency_kitchen_batch_actions WHERE request_id = p_event_id) THEN
    RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
  END IF;
  IF line.kitchen_done_quantity <= line.floor_served_quantity THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = line.order_id AND o.sales_channel = 'delivery')
    AND NOT public.direct_order_is_pickup_pos_order(line.order_id, line.restaurant_id) THEN
    SELECT * INTO lot FROM public.emergency_floor_ready_lots l
    WHERE l.source_kind = p_source_kind AND l.source_id = line.id
      AND l.ready_quantity > l.served_quantity + l.voided_quantity
    ORDER BY l.ready_sequence DESC, l.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots SET voided_quantity = voided_quantity + 1, updated_at = now()
    WHERE id = lot.id;
  END IF;
  IF p_source_kind = 'base' THEN
    UPDATE public.emergency_fulfillment_items SET
      kitchen_started_quantity = kitchen_done_quantity - 1,
      kitchen_done_quantity = kitchen_done_quantity - 1,
      tray_received_quantity = kitchen_done_quantity - 1,
      tray_dispatched_quantity = kitchen_done_quantity - 1, updated_at = now() WHERE id = line.id;
  ELSE
    UPDATE public.emergency_combo_component_items SET
      kitchen_started_quantity = kitchen_done_quantity - 1,
      kitchen_done_quantity = kitchen_done_quantity - 1,
      tray_received_quantity = kitchen_done_quantity - 1,
      tray_dispatched_quantity = kitchen_done_quantity - 1, updated_at = now() WHERE id = line.id;
    SELECT id INTO parent_id FROM public.emergency_fulfillment_items p
    WHERE p.session_id = line.session_id AND p.order_item_id = line.order_item_id FOR UPDATE;
    SELECT COALESCE(min(c.kitchen_done_quantity * p.ordered_quantity / c.ordered_quantity), 0)::integer
    INTO parent_done FROM public.emergency_combo_component_items c
    JOIN public.emergency_fulfillment_items p ON p.id = parent_id
    WHERE c.session_id = line.session_id AND c.order_item_id = line.order_item_id AND NOT c.is_cancelled;
    UPDATE public.emergency_fulfillment_items SET kitchen_started_quantity = parent_done,
      kitchen_done_quantity = parent_done, tray_received_quantity = parent_done,
      tray_dispatched_quantity = parent_done, updated_at = now() WHERE id = parent_id;
  END IF;
  UPDATE public.direct_delivery_fulfillment_tickets t
  SET status = 'preparing', version = t.version + 1, ready_at = NULL, updated_at = now()
  FROM public.direct_order_financials f
  WHERE f.order_id = line.order_id AND f.restaurant_id = actor.restaurant_id
    AND t.request_id = f.request_id AND t.status = 'ready';
  response := jsonb_build_object('kitchen_started_quantity', line.kitchen_done_quantity - 1,
    'kitchen_done_quantity', line.kitchen_done_quantity - 1,
    'tray_received_quantity', line.kitchen_done_quantity - 1,
    'tray_dispatched_quantity', line.kitchen_done_quantity - 1,
    'floor_served_quantity', line.floor_served_quantity,
    'oldest_ready_sequence', (SELECT min(ready_sequence) FROM public.emergency_floor_ready_lots l
      WHERE l.source_kind = p_source_kind AND l.source_id = line.id
        AND l.ready_quantity > l.served_quantity + l.voided_quantity));
  INSERT INTO public.emergency_fulfillment_events(event_id, session_id, restaurant_id, order_id,
    order_item_id, combo_component_item_id, stage, delta, actor_user_id, details)
  VALUES(p_event_id, line.session_id, line.restaurant_id, line.order_id, line.order_item_id,
    CASE WHEN p_source_kind = 'combo_component' THEN line.id END, 'kitchen_done', -1, actor.id,
    jsonb_build_object('kitchen_direct_to_floor', true, 'source_kind', p_source_kind,
      'source_id', line.id, 'workflow_action', 'kitchen_done', 'response', response));
  RETURN response || jsonb_build_object('event_id', p_event_id, 'deduplicated', false);
END;
$$;
REVOKE ALL ON FUNCTION public.kds_record_direct_kitchen_v1(uuid,text,integer,uuid) FROM PUBLIC, anon, authenticated;

-- Route single-item and durable legacy outbox commands through the same server
-- authority. A floor still performs its own authenticated service command.
SELECT pg_temp.kds_direct_patch('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)',
  $old$BEGIN
  IF p_item_id IS NULL$old$,
  $new$BEGIN
  IF p_action IN ('kitchen_done', 'kitchen_started') AND EXISTS (
    SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
      AND public.kds_is_direct_floor_store(u.restaurant_id)
  ) THEN RETURN public.kds_record_direct_kitchen_v1(p_item_id, p_source_kind, p_delta, p_event_id); END IF;
  IF p_item_id IS NULL$new$);
SELECT pg_temp.kds_direct_patch('public.emergency_record_progress(uuid,text,integer,uuid)',
  $old$BEGIN
$old$,
  $new$BEGIN
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
    AND public.kds_is_direct_floor_store(u.restaurant_id)) THEN
    IF p_stage = 'kitchen_done' THEN RETURN public.kds_record_direct_kitchen_v1(p_fulfillment_item_id, 'base', p_delta, p_event_id); END IF;
    IF p_stage = 'floor_served' THEN RETURN public.kds_record_station_progress_v3(p_fulfillment_item_id, 'base', p_stage, p_delta, p_event_id); END IF;
    RAISE EXCEPTION 'JEONGABOK_CHECKER_RETIRED';
  END IF;
$new$);
SELECT pg_temp.kds_direct_patch('public.emergency_record_combo_component_progress(uuid,text,integer,uuid)',
  $old$BEGIN
$old$,
  $new$BEGIN
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active
    AND public.kds_is_direct_floor_store(u.restaurant_id)) THEN
    IF p_stage = 'kitchen_done' THEN RETURN public.kds_record_direct_kitchen_v1(p_component_item_id, 'combo_component', p_delta, p_event_id); END IF;
    IF p_stage = 'floor_served' THEN RETURN public.kds_record_station_progress_v3(p_component_item_id, 'combo_component', p_stage, p_delta, p_event_id); END IF;
    RAISE EXCEPTION 'JEONGABOK_CHECKER_RETIRED';
  END IF;
$new$);

-- Snapshot enrichment remains one set join over the requested queues. JSON
-- expansion is in-memory; there is no SQL/RPC lookup per displayed item.
ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb) RENAME TO emergency_enrich_start_ready_orders_pre_direct;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders_pre_direct(jsonb) FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.emergency_enrich_start_ready_orders(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  WITH orders AS MATERIALIZED (
    SELECT o.value, o.ordinality AS ord, COALESCE(q.kitchen_direct_to_floor, false) AS direct
    FROM jsonb_array_elements(public.emergency_enrich_start_ready_orders_pre_direct(p_orders))
      WITH ORDINALITY o(value, ordinality)
    LEFT JOIN public.emergency_order_queue q ON q.id = NULLIF(o.value->>'queue_id', '')::uuid
  ), items AS (
    SELECT o.ord, jsonb_agg(i.value || jsonb_build_object('kitchen_direct_to_floor', o.direct)
      ORDER BY i.ordinality) AS value
    FROM orders o CROSS JOIN LATERAL jsonb_array_elements(o.value->'items') WITH ORDINALITY i(value, ordinality)
    GROUP BY o.ord
  )
  SELECT COALESCE(jsonb_agg(o.value || jsonb_build_object('kitchen_direct_to_floor', o.direct,
    'items', COALESCE(i.value, '[]'::jsonb)) ORDER BY o.ord), '[]'::jsonb)
  FROM orders o LEFT JOIN items i ON i.ord = o.ord;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC, anon, authenticated;
ALTER FUNCTION public.get_emergency_station_snapshot() RENAME TO get_emergency_station_snapshot_pre_direct;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_direct() FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE payload jsonb;
BEGIN
  payload := public.get_emergency_station_snapshot_pre_direct();
  RETURN payload || jsonb_build_object('kitchen_direct_to_floor',
    public.kds_is_direct_floor_store((payload->>'restaurant_id')::uuid));
END;
$$;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot() TO authenticated;

-- Leftover packaging is floor -> kitchen -> floor. New stages retain truthful
-- actors instead of synthesizing actions attributed to an absent checker.
DO $$
DECLARE definition text; constraint_name text;
BEGIN
  SELECT conname, pg_get_constraintdef(oid) INTO constraint_name, definition
  FROM pg_constraint WHERE conrelid = 'public.emergency_fulfillment_events'::regclass
    AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%leftover_requested%';
  IF constraint_name IS NULL THEN RAISE EXCEPTION 'KDS_EVENT_STAGE_CONSTRAINT_MISSING'; END IF;
  EXECUTE format('ALTER TABLE public.emergency_fulfillment_events DROP CONSTRAINT %I, ADD CONSTRAINT %I %s',
    constraint_name, constraint_name, replace(definition, '''leftover_requested''::text',
      '''leftover_floor_to_kitchen''::text, ''leftover_kitchen_to_floor''::text, ''leftover_requested''::text'));
END;
$$;
SELECT pg_temp.kds_direct_patch('public.emergency_advance_leftover_packaging(uuid,uuid)',
  $old$('awaiting_floor_pickup', 'floor', 'awaiting_tray_to_kitchen',
      'leftover_floor_to_tray', 'tray')$old$,
  $new$('awaiting_floor_pickup', 'floor',
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'awaiting_kitchen_packaging' ELSE 'awaiting_tray_to_kitchen' END,
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'leftover_floor_to_kitchen' ELSE 'leftover_floor_to_tray' END,
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'kitchen' ELSE 'tray' END)$new$);
SELECT pg_temp.kds_direct_patch('public.emergency_advance_leftover_packaging(uuid,uuid)',
  $old$('awaiting_kitchen_packaging', 'kitchen', 'awaiting_tray_return',
      'leftover_kitchen_packaged', 'tray')$old$,
  $new$('awaiting_kitchen_packaging', 'kitchen',
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'awaiting_floor_delivery' ELSE 'awaiting_tray_return' END,
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'leftover_kitchen_to_floor' ELSE 'leftover_kitchen_packaged' END,
      CASE WHEN public.kds_is_direct_floor_store(v_request.restaurant_id) THEN 'floor' ELSE 'tray' END)$new$);

DO $$
BEGIN
  IF EXISTS (
    (SELECT * FROM kds_other_store_before)
    EXCEPT
    (SELECT 'users', md5(COALESCE(jsonb_agg(to_jsonb(u) ORDER BY u.id)::text, '[]'))
      FROM public.users u WHERE NOT public.kds_is_direct_floor_store(u.restaurant_id)
    UNION ALL SELECT 'requirements', md5(COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id)::text, '[]'))
      FROM public.store_fixed_account_requirements q WHERE NOT public.kds_is_direct_floor_store(q.store_id)
    UNION ALL SELECT 'assignments', md5(COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text, '[]'))
      FROM public.emergency_station_assignments a WHERE NOT public.kds_is_direct_floor_store(a.restaurant_id)
    UNION ALL SELECT 'settings', md5(COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.restaurant_id)::text, '[]'))
      FROM public.restaurant_settings s WHERE NOT public.kds_is_direct_floor_store(s.restaurant_id))
  ) THEN RAISE EXCEPTION 'KDS_OTHER_STORE_PRESERVATION_FAILED'; END IF;
  IF EXISTS (SELECT 1 FROM public.emergency_station_assignments
    WHERE public.kds_is_direct_floor_store(restaurant_id) AND station_type = 'tray' AND is_active)
  OR EXISTS (SELECT 1 FROM public.store_fixed_account_requirements
    WHERE public.kds_is_direct_floor_store(store_id) AND account_code ~ '_(tray1|tray)$' AND is_active)
  OR EXISTS (SELECT 1 FROM public.users WHERE public.kds_is_direct_floor_store(restaurant_id)
    AND fixed_account_code ~ '_(tray1|tray)$' AND is_active) THEN
    RAISE EXCEPTION 'JEONGABOK_CHECKER_RETIREMENT_FAILED';
  END IF;
  IF has_function_privilege('authenticated', 'public.kds_record_direct_kitchen_v1(uuid,text,integer,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.get_emergency_station_snapshot()', 'EXECUTE') THEN
    RAISE EXCEPTION 'KDS_DIRECT_INTERNAL_FUNCTION_EXPOSED';
  END IF;
END;
$$;
NOTIFY pgrst, 'reload schema';
COMMIT;
