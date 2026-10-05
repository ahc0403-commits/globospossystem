-- Approved, prepaid pickups share the kitchen -> tray quantity ledgers.
-- Payment completion and customer pickup remain separate operations.
-- production-gate: self-verifying
BEGIN;

CREATE FUNCTION pg_temp.pickup_kds_patch(signature text, old_text text, new_text text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef(to_regprocedure(signature));
  IF definition IS NULL OR
     (length(definition) - length(replace(definition, old_text, ''))) / length(old_text) <> 1 THEN
    RAISE EXCEPTION 'PICKUP_KDS_PREDECESSOR_DRIFT:%', signature;
  END IF;
  EXECUTE replace(definition, old_text, new_text);
END;
$$;

-- Retain the direct-order exclusion in the ordinary item-insert triggers.
-- Enqueue only after approval has committed its financial graph, not while
-- process_payment is inserting already-served accounting lines.
CREATE FUNCTION public.enqueue_direct_pickup_kds(p_store_id uuid, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
DECLARE
  request public.direct_order_requests%ROWTYPE;
  financial public.direct_order_financials%ROWTYPE;
  ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  session_row public.emergency_fulfillment_sessions%ROWTYPE;
  queue public.emergency_order_queue%ROWTYPE;
  item public.emergency_fulfillment_items%ROWTYPE;
  event_id uuid;
  added integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:' || p_request_id::text, 0));
  SELECT * INTO request FROM public.direct_order_requests
  WHERE id = p_request_id AND restaurant_id = p_store_id FOR UPDATE;
  IF NOT FOUND OR request.fulfillment_type <> 'pickup' OR request.state <> 'approved' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_APPROVED';
  END IF;
  SELECT * INTO financial FROM public.direct_order_financials
  WHERE request_id = p_request_id AND restaurant_id = p_store_id;
  IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM public.orders o JOIN public.payments p ON p.order_id = o.id
    WHERE o.id = financial.order_id AND o.restaurant_id = p_store_id
      AND o.sales_channel = 'takeaway' AND o.status = 'completed'
      AND p.id = financial.payment_id AND p.restaurant_id = p_store_id
      AND p.amount_portion = financial.final_total
  ) THEN RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED'; END IF;
  SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets
  WHERE request_id = p_request_id AND restaurant_id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
  IF ticket.status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'already_in_progress', 'order_id', financial.order_id);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('fulfillment-mode:' || p_store_id::text, 0));
  IF public.get_store_fulfillment_mode(p_store_id) <> 'paperless' THEN
    RETURN jsonb_build_object('status', 'pos_print', 'order_id', financial.order_id);
  END IF;
  SELECT * INTO session_row FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = p_store_id AND status = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_KDS_SESSION_REQUIRED'; END IF;

  SELECT * INTO queue FROM public.emergency_order_queue
  WHERE session_id = session_row.id AND order_id = financial.order_id;
  IF NOT FOUND THEN
    INSERT INTO public.emergency_order_queue (
      session_id, restaurant_id, order_id, queue_no, table_number,
      floor_label, workflow_version, created_at
    ) VALUES (
      session_row.id, p_store_id, financial.order_id,
      COALESCE((SELECT max(queue_no) + 1 FROM public.emergency_order_queue
        WHERE session_id = session_row.id), 1),
      request.reference_code, '1F', 1, request.created_at
    ) RETURNING * INTO queue;
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, stage, delta, details
    ) VALUES (
      gen_random_uuid(), session_row.id, p_store_id, financial.order_id,
      'order_received', 1,
      jsonb_build_object('event_scope', 'queue', 'queue_no', queue.queue_no,
        'fulfillment_type', 'pickup')
    );
  END IF;
  FOR item IN
    INSERT INTO public.emergency_fulfillment_items (
      session_id, restaurant_id, queue_id, order_id, order_item_id,
      source_quantity, ordered_quantity
    )
    SELECT session_row.id, p_store_id, queue.id, financial.order_id, i.id, i.quantity, i.quantity
    FROM public.order_items i
    WHERE i.order_id = financial.order_id AND i.restaurant_id = p_store_id
      AND i.item_type = 'menu_item' AND NOT COALESCE(i.is_service_item, false)
      AND i.status <> 'cancelled'
    ON CONFLICT (session_id, order_item_id) DO NOTHING
    RETURNING *
  LOOP
    added := added + 1;
    event_id := gen_random_uuid();
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, order_item_id, stage, delta, details
    ) VALUES (
      event_id, session_row.id, p_store_id, financial.order_id, item.order_item_id,
      'order_received', item.ordered_quantity,
      jsonb_build_object('event_scope', 'line', 'line_key', 'base',
        'fulfillment_route', 'kitchen_tray_floor', 'fulfillment_type', 'pickup')
    );
    PERFORM public.emergency_enqueue_push(event_id, p_store_id, financial.order_id,
      'kitchen', queue.floor_label, 'order_received');
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_items
    WHERE queue_id = queue.id AND NOT is_cancelled) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_ITEMS_REQUIRED';
  END IF;
  IF added > 0 THEN
    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (NULL, 'direct_order_pickup_kds_queued', 'direct_order_requests', p_request_id,
      jsonb_build_object('store_id', p_store_id, 'order_id', financial.order_id,
        'queue_id', queue.id, 'added_lines', added));
  END IF;
  RETURN jsonb_build_object('status', 'queued', 'queue_id', queue.id,
    'order_id', financial.order_id, 'added_lines', added);
END;
$$;
REVOKE ALL ON FUNCTION public.enqueue_direct_pickup_kds(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_direct_pickup_kds(uuid, uuid) TO service_role;

CREATE FUNCTION public.enqueue_direct_pickup_kds_after_approval()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
BEGIN
  IF NEW.fulfillment_type = 'pickup' AND NEW.state = 'approved'
     AND OLD.state IS DISTINCT FROM NEW.state THEN
    PERFORM public.enqueue_direct_pickup_kds(NEW.restaurant_id, NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.enqueue_direct_pickup_kds_after_approval() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER direct_pickup_kds_after_approval AFTER UPDATE OF state ON public.direct_order_requests
FOR EACH ROW EXECUTE FUNCTION public.enqueue_direct_pickup_kds_after_approval();

-- A pickup is a takeaway in accounting, with no floor delivery in fulfillment.
CREATE OR REPLACE FUNCTION public.emergency_add_order_sales_channels(p_orders jsonb, p_station_type text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
  SELECT COALESCE(jsonb_agg(
    order_row.raw || jsonb_build_object('sales_channel', COALESCE(o.sales_channel, 'dine_in')) ||
    CASE WHEN request.fulfillment_type = 'pickup' THEN jsonb_build_object(
      'direct_fulfillment_type', 'pickup', 'direct_reference_code', request.reference_code,
      'items', COALESCE((SELECT jsonb_agg(item.raw || jsonb_build_object('is_takeout', true)
        ORDER BY item.ord) FROM jsonb_array_elements(order_row.raw->'items')
        WITH ORDINALITY item(raw, ord)), '[]'::jsonb)) ELSE '{}'::jsonb END
    ORDER BY order_row.ord), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_orders, '[]'::jsonb)) WITH ORDINALITY order_row(raw, ord)
  LEFT JOIN public.orders o ON o.id = CASE WHEN order_row.raw->>'order_id' ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN (order_row.raw->>'order_id')::uuid ELSE NULL END
  LEFT JOIN public.direct_order_financials f ON f.order_id = o.id AND f.restaurant_id = o.restaurant_id
  LEFT JOIN public.direct_order_requests request ON request.id = f.request_id
    AND request.restaurant_id = o.restaurant_id
  WHERE p_station_type <> 'floor' OR (COALESCE(o.sales_channel, 'dine_in') <> 'delivery'
    AND COALESCE(request.fulfillment_type, 'delivery') <> 'pickup');
$$;

SELECT pg_temp.pickup_kds_patch('public.get_kds_ticket_v2(uuid)',
  $old$v_assignment.station_type = 'floor' AND v_sales_channel = 'delivery'$old$,
  $new$v_assignment.station_type = 'floor' AND (v_sales_channel = 'delivery'
    OR public.direct_order_is_pickup_pos_order(v_queue.order_id, v_queue.restaurant_id))$new$);
SELECT pg_temp.pickup_kds_patch('public.emergency_enqueue_push(uuid,uuid,uuid,text,text,text)',
  $old$order_row.sales_channel = 'delivery'$old$,
  $new$(order_row.sales_channel = 'delivery'
            OR public.direct_order_is_pickup_pos_order(order_row.id, order_row.restaurant_id))$new$);
SELECT pg_temp.pickup_kds_patch('public.kds_capture_fulfillment_event()',
  $old$COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'$old$,
  $new$(COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
    OR public.direct_order_is_pickup_pos_order(order_row.id, order_row.restaurant_id))$new$);
SELECT pg_temp.pickup_kds_patch('public.kds_set_workflow_event_targets()',
  $old$COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'$old$,
  $new$(COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
    OR public.direct_order_is_pickup_pos_order(order_row.id, order_row.restaurant_id))$new$);

SELECT pg_temp.pickup_kds_patch('public.emergency_record_progress(uuid,text,integer,uuid)',
  $old$  SELECT * INTO v_queue FROM public.emergency_order_queue WHERE id = v_item.queue_id;$old$,
  $new$  SELECT * INTO v_queue FROM public.emergency_order_queue WHERE id = v_item.queue_id;
  IF public.direct_order_is_pickup_pos_order(v_queue.order_id, v_queue.restaurant_id) THEN
    IF p_stage = 'floor_served' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FLOOR_FORBIDDEN'; END IF;
    IF EXISTS (SELECT 1 FROM public.direct_order_financials f
      JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id = f.request_id
      WHERE f.order_id = v_queue.order_id AND t.status IN ('completed', 'cancelled')) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_HANDOFF_FINALIZED';
    END IF;
  END IF;$new$);

-- Apply the same terminal/floor guard to whole-order completion and undo.
DO $bulk_guards$
DECLARE signature text; old_text text; new_text text;
BEGIN
  FOR signature, old_text IN VALUES
    ('public.emergency_complete_order_stage(uuid,uuid)', '  v_stage := CASE v_assignment.station_type'),
    ('public.emergency_revert_order_action(uuid,uuid,uuid)', '  SELECT * INTO v_original')
  LOOP
    new_text := $guard$  IF public.direct_order_is_pickup_pos_order(v_queue.order_id, v_queue.restaurant_id) THEN
    IF v_assignment.station_type = 'floor' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FLOOR_FORBIDDEN'; END IF;
    IF EXISTS (SELECT 1 FROM public.direct_order_financials f
      JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id = f.request_id
      WHERE f.order_id = v_queue.order_id AND t.status IN ('completed', 'cancelled')) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_HANDOFF_FINALIZED';
    END IF;
  END IF;
$guard$ || old_text;
    PERFORM pg_temp.pickup_kds_patch(signature, old_text, new_text);
  END LOOP;
END;
$bulk_guards$;

-- Reuse the current status-sync trigger, preserving delivery's Grab lifecycle.
SELECT pg_temp.pickup_kds_patch('public.sync_direct_delivery_ticket_from_kds()',
  $old$  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN RETURN NEW; END IF;$old$,
  $new$  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN
    IF NEW.stage NOT IN ('kitchen_done', 'tray_dispatched') THEN RETURN NEW; END IF;
    SELECT t.* INTO v_ticket FROM public.direct_delivery_fulfillment_tickets t
    JOIN public.direct_order_financials f ON f.request_id = t.request_id
    WHERE f.order_id = NEW.order_id AND f.restaurant_id = NEW.restaurant_id FOR UPDATE OF t;
    IF NOT FOUND OR v_ticket.status IN ('completed', 'cancelled') THEN RETURN NEW; END IF;
    IF NEW.stage = 'tray_dispatched' AND NEW.delta > 0 AND NOT EXISTS (
      SELECT 1 FROM public.emergency_fulfillment_items i WHERE i.order_id = NEW.order_id
        AND NOT i.is_cancelled AND i.tray_dispatched_quantity < i.ordered_quantity - i.excused_quantity
    ) THEN
      UPDATE public.direct_delivery_fulfillment_tickets SET status = 'ready', version = version + 1,
        accepted_at = COALESCE(accepted_at, now()), ready_at = now(), updated_at = now()
      WHERE id = v_ticket.id AND status <> 'ready';
    ELSIF (NEW.stage = 'kitchen_done' AND NEW.delta > 0 AND v_ticket.status = 'pending')
       OR (NEW.delta < 0 AND v_ticket.status = 'ready') THEN
      UPDATE public.direct_delivery_fulfillment_tickets SET status = 'preparing', version = version + 1,
        accepted_at = COALESCE(accepted_at, now()), ready_at = NULL, updated_at = now()
      WHERE id = v_ticket.id;
    END IF;
    RETURN NEW;
  END IF;$new$);

-- The dedicated direct board remains the print-store fallback. Paperless
-- pickups have one preparation authority: the kitchen/tray quantity ledgers.
SELECT pg_temp.pickup_kds_patch('public.direct_delivery_ticket_list(uuid,text[],timestamp with time zone,uuid,integer)',
  $old$      WHERE ticket.restaurant_id = p_store_id$old$,
  $new$      WHERE ticket.restaurant_id = p_store_id
        AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials f
          JOIN public.emergency_order_queue q ON q.order_id = f.order_id
          JOIN public.direct_order_requests r ON r.id = f.request_id
          WHERE f.request_id = ticket.request_id AND r.fulfillment_type = 'pickup')$new$);

-- Prevent stale dedicated-board clients from bypassing the quantity handoff.
SELECT pg_temp.pickup_kds_patch('public.direct_delivery_ticket_transition(uuid,uuid,integer,text)',
  $old$  IF v_ticket.version <> p_expected_version THEN$old$,
  $new$  IF p_next_status IN ('preparing', 'ready') AND EXISTS (
    SELECT 1 FROM public.direct_order_requests r
    JOIN public.direct_order_financials f ON f.request_id = r.id
    JOIN public.emergency_order_queue q ON q.order_id = f.order_id
    WHERE r.id = v_ticket.request_id AND r.fulfillment_type = 'pickup'
  ) THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_USE_KDS'; END IF;
  IF v_ticket.version <> p_expected_version THEN$new$);

DO $verify$
BEGIN
  IF has_function_privilege('anon', 'public.enqueue_direct_pickup_kds(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.enqueue_direct_pickup_kds(uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.enqueue_direct_pickup_kds(uuid,uuid)', 'EXECUTE')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.direct_order_requests'::regclass
       AND tgname = 'direct_pickup_kds_after_approval' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'DIRECT_PICKUP_KDS_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
