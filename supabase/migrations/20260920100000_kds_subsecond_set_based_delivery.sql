BEGIN;

-- production-gate: self-verifying

-- Keep the immediately preceding implementations available for a fast,
-- metadata-only rollback. They are deliberately not executable by clients.
ALTER FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  RENAME TO kds_complete_kitchen_batch_loop_backup_v1;
ALTER FUNCTION public.kds_dispatch_tray_floor_batch_v1(uuid, text, jsonb)
  RENAME TO kds_dispatch_tray_floor_loop_backup_v1;
ALTER FUNCTION public.kds_complete_customer_delivery_batch_v1(uuid, jsonb)
  RENAME TO kds_complete_customer_delivery_loop_backup_v1;

REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_loop_backup_v1(
  uuid, jsonb
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kds_dispatch_tray_floor_loop_backup_v1(
  uuid, text, jsonb
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kds_complete_customer_delivery_loop_backup_v1(
  uuid, jsonb
) FROM PUBLIC, anon, authenticated;

-- Apply a whole operator selection with a fixed number of set operations.
-- There is one audit event per selected line (delta may be greater than one),
-- rather than one nested RPC call and one audit event per physical unit.
CREATE OR REPLACE FUNCTION public.kds_apply_station_progress_batch_v1(
  p_request_id uuid,
  p_restaurant_id uuid,
  p_actor_user_id uuid,
  p_action text,
  p_floor_label text,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_allocation_count integer;
  v_changed_quantity integer;
  v_matched_count integer;
  v_workflow_two_quantity integer := 0;
  v_tray_sequence_end bigint;
  v_floor_sequence_end bigint;
  v_event_ids jsonb := '[]'::jsonb;
BEGIN
  IF p_request_id IS NULL OR p_restaurant_id IS NULL
     OR p_actor_user_id IS NULL
     OR p_action NOT IN ('kitchen_done', 'tray_dispatched', 'floor_served')
     OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_BATCH_INPUT_INVALID';
  END IF;

  SELECT count(*)::integer, COALESCE(sum(a.quantity), 0)::integer
  INTO v_allocation_count, v_changed_quantity
  FROM jsonb_to_recordset(p_allocations) AS a(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_allocation_count > 1000 OR v_changed_quantity <= 0
     OR v_changed_quantity > 1000 OR EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE a.item_id IS NULL
      OR a.source_kind NOT IN ('base', 'combo_component')
      OR a.quantity IS NULL OR a.quantity <= 0
  ) OR EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    GROUP BY a.item_id, a.source_kind
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_INPUT_INVALID';
  END IF;

  -- A single global lock order prevents two mixed base/combo batches from
  -- deadlocking while still allowing different stores to progress in parallel.
  BEGIN
    PERFORM item.id
    FROM public.emergency_fulfillment_items item
    JOIN jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = item.id
      AND allocation.source_kind = 'base'
    ORDER BY item.id
    FOR UPDATE OF item NOWAIT;

    PERFORM component.id
    FROM public.emergency_combo_component_items component
    JOIN jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = component.id
      AND allocation.source_kind = 'combo_component'
    ORDER BY component.id
    FOR UPDATE OF component NOWAIT;

    PERFORM parent.id
    FROM public.emergency_fulfillment_items parent
    JOIN (
      SELECT DISTINCT component.session_id, component.order_item_id
      FROM public.emergency_combo_component_items component
      JOIN jsonb_to_recordset(p_allocations) AS allocation(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      ) ON allocation.item_id = component.id
        AND allocation.source_kind = 'combo_component'
    ) affected ON affected.session_id = parent.session_id
      AND affected.order_item_id = parent.order_item_id
    ORDER BY parent.id
    FOR UPDATE OF parent NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), lines AS (
    SELECT item.id AS item_id, item.queue_id, 'base'::text AS source_kind,
      item.session_id, item.order_id, item.order_item_id,
      item.ordered_quantity, item.excused_quantity,
      item.kitchen_done_quantity, item.tray_dispatched_quantity,
      item.floor_served_quantity, queue.workflow_version,
      queue.floor_label, COALESCE(order_row.sales_channel, 'dine_in') AS channel,
      allocation.quantity
    FROM allocations allocation
    JOIN public.emergency_fulfillment_items item
      ON item.id = allocation.item_id
     AND allocation.source_kind = 'base'
    JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = item.order_id
    WHERE item.restaurant_id = p_restaurant_id
      AND item.is_cancelled = false AND item.needs_review = false
      AND (allocation.queue_id IS NULL OR allocation.queue_id = item.queue_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )
    UNION ALL
    SELECT component.id, component.queue_id, 'combo_component',
      component.session_id, component.order_id, component.order_item_id,
      component.ordered_quantity, component.excused_quantity,
      component.kitchen_done_quantity, component.tray_dispatched_quantity,
      component.floor_served_quantity, queue.workflow_version,
      queue.floor_label, COALESCE(order_row.sales_channel, 'dine_in'),
      allocation.quantity
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
    JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = component.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = component.order_id
    WHERE component.restaurant_id = p_restaurant_id
      AND component.is_cancelled = false AND component.needs_review = false
      AND (allocation.queue_id IS NULL OR allocation.queue_id = component.queue_id)
  )
  SELECT count(*)::integer,
    COALESCE(sum(quantity) FILTER (WHERE workflow_version = 2), 0)::integer
  INTO v_matched_count, v_workflow_two_quantity
  FROM lines
  WHERE CASE p_action
    WHEN 'kitchen_done' THEN
      kitchen_done_quantity + quantity <= ordered_quantity - excused_quantity
    WHEN 'tray_dispatched' THEN
      workflow_version = 2 AND channel <> 'delivery'
      AND upper(btrim(floor_label)) = upper(btrim(p_floor_label))
      AND tray_dispatched_quantity + quantity <= kitchen_done_quantity
    WHEN 'floor_served' THEN
      workflow_version = 2 AND channel <> 'delivery'
      AND upper(btrim(floor_label)) = upper(btrim(p_floor_label))
      AND floor_served_quantity + quantity <= tray_dispatched_quantity
    ELSE false END;

  IF v_matched_count <> v_allocation_count THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;

  IF p_action = 'tray_dispatched' AND EXISTS (
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
  END IF;

  IF p_action = 'floor_served' AND EXISTS (
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
  END IF;

  IF p_action = 'kitchen_done' AND v_workflow_two_quantity > 0 THEN
    INSERT INTO public.emergency_tray_ready_sequences AS sequence(
      restaurant_id, current_sequence, updated_at
    ) VALUES (p_restaurant_id, v_workflow_two_quantity, now())
    ON CONFLICT (restaurant_id) DO UPDATE
    SET current_sequence = sequence.current_sequence
          + EXCLUDED.current_sequence,
        updated_at = now()
    RETURNING current_sequence INTO v_tray_sequence_end;

    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), lines AS (
      SELECT item.id AS item_id, item.session_id, item.queue_id, item.order_id,
        item.order_item_id, 'base'::text AS source_kind, allocation.quantity,
        queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue
        ON queue.id = item.queue_id AND queue.workflow_version = 2
      UNION ALL
      SELECT component.id, component.session_id, component.queue_id,
        component.order_id, component.order_item_id, 'combo_component',
        allocation.quantity, queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue
        ON queue.id = component.queue_id AND queue.workflow_version = 2
    ), ranked AS (
      SELECT lines.*,
        COALESCE(sum(quantity) OVER (
          ORDER BY created_at, queue_no, queue_id, source_kind, item_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::bigint AS sequence_offset
      FROM lines
    )
    INSERT INTO public.emergency_tray_ready_lots(
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, kitchen_event_id, ready_sequence, ready_quantity
    )
    SELECT p_restaurant_id, ranked.session_id, ranked.queue_id,
      ranked.order_id, ranked.order_item_id, ranked.source_kind, ranked.item_id,
      md5(p_request_id::text || ':kitchen_done:' || ranked.source_kind || ':'
        || ranked.item_id::text)::uuid,
      v_tray_sequence_end - v_workflow_two_quantity
        + ranked.sequence_offset + 1,
      ranked.quantity
    FROM ranked;
  END IF;

  IF p_action = 'tray_dispatched' THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), candidates AS (
      SELECT lot.id, allocation.item_id, allocation.source_kind,
        allocation.quantity,
        lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
          AS available,
        COALESCE(sum(
          lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
        ) OVER (
          PARTITION BY allocation.item_id, allocation.source_kind
          ORDER BY lot.ready_sequence, lot.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::integer AS consumed_before
      FROM allocations allocation
      JOIN public.emergency_tray_ready_lots lot
        ON lot.source_kind = allocation.source_kind
       AND lot.source_id = allocation.item_id
       AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity
    ), consumed AS (
      SELECT id, LEAST(
        available, GREATEST(quantity - consumed_before, 0)
      )::integer AS take_quantity
      FROM candidates
    )
    UPDATE public.emergency_tray_ready_lots lot
    SET handed_quantity = lot.handed_quantity + consumed.take_quantity,
        updated_at = now()
    FROM consumed
    WHERE lot.id = consumed.id AND consumed.take_quantity > 0;

    INSERT INTO public.emergency_floor_ready_sequences AS sequence(
      restaurant_id, current_sequence, updated_at
    ) VALUES (p_restaurant_id, v_changed_quantity, now())
    ON CONFLICT (restaurant_id) DO UPDATE
    SET current_sequence = sequence.current_sequence
          + EXCLUDED.current_sequence,
        updated_at = now()
    RETURNING current_sequence INTO v_floor_sequence_end;

    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), lines AS (
      SELECT item.id AS item_id, item.session_id, item.queue_id, item.order_id,
        item.order_item_id, 'base'::text AS source_kind, allocation.quantity,
        queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      UNION ALL
      SELECT component.id, component.session_id, component.queue_id,
        component.order_id, component.order_item_id, 'combo_component',
        allocation.quantity, queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    ), ranked AS (
      SELECT lines.*,
        COALESCE(sum(quantity) OVER (
          ORDER BY created_at, queue_no, queue_id, source_kind, item_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::bigint AS sequence_offset
      FROM lines
    )
    INSERT INTO public.emergency_floor_ready_lots(
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, ready_action_id, ready_sequence, ready_quantity
    )
    SELECT p_restaurant_id, ranked.session_id, ranked.queue_id,
      ranked.order_id, ranked.order_item_id, ranked.source_kind, ranked.item_id,
      md5(p_request_id::text || ':tray_dispatched:' || ranked.source_kind || ':'
        || ranked.item_id::text)::uuid,
      v_floor_sequence_end - v_changed_quantity
        + ranked.sequence_offset + 1,
      ranked.quantity
    FROM ranked;
  ELSIF p_action = 'floor_served' THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), candidates AS (
      SELECT lot.id, allocation.item_id, allocation.source_kind,
        allocation.quantity,
        lot.ready_quantity - lot.served_quantity - lot.voided_quantity
          AS available,
        COALESCE(sum(
          lot.ready_quantity - lot.served_quantity - lot.voided_quantity
        ) OVER (
          PARTITION BY allocation.item_id, allocation.source_kind
          ORDER BY lot.ready_sequence, lot.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::integer AS consumed_before
      FROM allocations allocation
      JOIN public.emergency_floor_ready_lots lot
        ON lot.source_kind = allocation.source_kind
       AND lot.source_id = allocation.item_id
       AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ), consumed AS (
      SELECT id, LEAST(
        available, GREATEST(quantity - consumed_before, 0)
      )::integer AS take_quantity
      FROM candidates
    )
    UPDATE public.emergency_floor_ready_lots lot
    SET served_quantity = lot.served_quantity + consumed.take_quantity,
        updated_at = now()
    FROM consumed
    WHERE lot.id = consumed.id AND consumed.take_quantity > 0;
  END IF;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  )
  UPDATE public.emergency_fulfillment_items item
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN item.kitchen_started_quantity + allocation.quantity
        ELSE item.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN item.kitchen_done_quantity + allocation.quantity
        ELSE item.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN item.tray_received_quantity + allocation.quantity
        ELSE item.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN item.tray_dispatched_quantity + allocation.quantity
        ELSE item.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN item.floor_served_quantity + allocation.quantity
        ELSE item.floor_served_quantity END,
      updated_at = now()
  FROM allocations allocation
  WHERE allocation.source_kind = 'base' AND item.id = allocation.item_id;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  )
  UPDATE public.emergency_combo_component_items component
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN component.kitchen_started_quantity + allocation.quantity
        ELSE component.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN component.kitchen_done_quantity + allocation.quantity
        ELSE component.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN component.tray_received_quantity + allocation.quantity
        ELSE component.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN component.tray_dispatched_quantity + allocation.quantity
        ELSE component.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN component.floor_served_quantity + allocation.quantity
        ELSE component.floor_served_quantity END,
      updated_at = now()
  FROM allocations allocation
  WHERE allocation.source_kind = 'combo_component'
    AND component.id = allocation.item_id;

  -- Recompute every affected combo parent once, after all component rows have
  -- advanced. This preserves the commercial-line projection without N+1 RPCs.
  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), affected AS (
    SELECT DISTINCT component.session_id, component.order_item_id
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
  ), parent_values AS (
    SELECT parent.id,
      COALESCE(min(
        CASE p_action
          WHEN 'kitchen_done' THEN component.kitchen_done_quantity
          WHEN 'tray_dispatched' THEN component.tray_dispatched_quantity
          ELSE component.floor_served_quantity
        END * parent.ordered_quantity / component.ordered_quantity
      ), 0)::integer AS stage_quantity
    FROM affected
    JOIN public.emergency_fulfillment_items parent
      ON parent.session_id = affected.session_id
     AND parent.order_item_id = affected.order_item_id
    JOIN public.emergency_combo_component_items component
      ON component.session_id = affected.session_id
     AND component.order_item_id = affected.order_item_id
     AND component.is_cancelled = false
    GROUP BY parent.id
  )
  UPDATE public.emergency_fulfillment_items parent
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN parent_values.stage_quantity ELSE parent.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN parent_values.stage_quantity ELSE parent.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN parent_values.stage_quantity ELSE parent.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched'
        THEN parent_values.stage_quantity ELSE parent.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN parent_values.stage_quantity ELSE parent.floor_served_quantity END,
      updated_at = now()
  FROM parent_values
  WHERE parent.id = parent_values.id;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), lines AS (
    SELECT item.id AS item_id, item.session_id, item.order_id,
      item.order_item_id, NULL::uuid AS combo_component_item_id,
      'base'::text AS source_kind, allocation.quantity,
      item.kitchen_started_quantity, item.kitchen_done_quantity,
      item.tray_received_quantity, item.tray_dispatched_quantity,
      item.floor_served_quantity
    FROM allocations allocation
    JOIN public.emergency_fulfillment_items item
      ON item.id = allocation.item_id AND allocation.source_kind = 'base'
    UNION ALL
    SELECT component.id, component.session_id, component.order_id,
      component.order_item_id, component.id, 'combo_component',
      allocation.quantity, component.kitchen_started_quantity,
      component.kitchen_done_quantity, component.tray_received_quantity,
      component.tray_dispatched_quantity, component.floor_served_quantity
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
  ), inserted AS (
    INSERT INTO public.emergency_fulfillment_events(
      event_id, session_id, restaurant_id, order_id, order_item_id,
      combo_component_item_id, stage, delta, actor_user_id, details
    )
    SELECT md5(p_request_id::text || ':' || p_action || ':'
        || lines.source_kind || ':' || lines.item_id::text)::uuid,
      lines.session_id, p_restaurant_id, lines.order_id, lines.order_item_id,
      lines.combo_component_item_id, p_action, lines.quantity, p_actor_user_id,
      jsonb_build_object(
        'workflow_action', p_action,
        'source_kind', lines.source_kind,
        'effective_action', p_action,
        'source_id', lines.item_id,
        'batch_request_id', p_request_id,
        'response', jsonb_build_object(
          'kitchen_started_quantity', lines.kitchen_started_quantity,
          'kitchen_done_quantity', lines.kitchen_done_quantity,
          'tray_received_quantity', lines.tray_received_quantity,
          'tray_dispatched_quantity', lines.tray_dispatched_quantity,
          'floor_served_quantity', lines.floor_served_quantity
        )
      )
    FROM lines
    RETURNING event_id
  )
  SELECT COALESCE(jsonb_agg(event_id ORDER BY event_id), '[]'::jsonb)
  INTO v_event_ids
  FROM inserted;

  -- Push fan-out is also one set operation. A slow or unavailable push worker
  -- therefore never holds the operator request open.
  IF p_action IN ('kitchen_done', 'tray_dispatched') THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), event_rows AS (
      SELECT md5(p_request_id::text || ':' || p_action || ':base:'
          || item.id::text)::uuid AS event_id,
        item.order_id, queue.floor_label,
        COALESCE(order_row.sales_channel, 'dine_in') AS channel
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.orders order_row ON order_row.id = item.order_id
      UNION ALL
      SELECT md5(p_request_id::text || ':' || p_action || ':combo_component:'
          || component.id::text)::uuid,
        component.order_id, queue.floor_label,
        COALESCE(order_row.sales_channel, 'dine_in')
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
      JOIN public.orders order_row ON order_row.id = component.order_id
    )
    INSERT INTO public.emergency_push_deliveries(
      event_id, restaurant_id, device_id, push_token, station_type,
      floor_label, order_id, stage
    )
    SELECT event_rows.event_id, p_restaurant_id, device.id, device.token,
      assignment.station_type, assignment.floor_label,
      event_rows.order_id, p_action
    FROM event_rows
    JOIN public.emergency_station_assignments assignment
      ON assignment.restaurant_id = p_restaurant_id
     AND assignment.is_active = true
     AND assignment.station_type = CASE p_action
       WHEN 'kitchen_done' THEN 'tray' ELSE 'floor' END
    JOIN public.emergency_web_push_devices device
      ON device.station_assignment_id = assignment.id
     AND device.restaurant_id = p_restaurant_id
     AND device.is_enabled = true
    WHERE (assignment.station_type <> 'floor'
      OR assignment.floor_label = event_rows.floor_label)
      AND NOT (assignment.station_type = 'floor'
        AND event_rows.channel = 'delivery')
    ON CONFLICT (event_id, device_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'changed_quantity', v_changed_quantity,
    'event_ids', v_event_ids
  );
EXCEPTION WHEN lock_not_available THEN
  RAISE EXCEPTION 'KDS_BATCH_STALE';
END;
$$;

REVOKE ALL ON FUNCTION public.kds_apply_station_progress_batch_v1(
  uuid, uuid, uuid, text, text, jsonb
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.kds_complete_kitchen_batch_v1(
  p_request_id uuid,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_existing public.emergency_kitchen_batch_actions%ROWTYPE;
  v_client_snapshot jsonb;
  v_hash text;
  v_count integer;
  v_changed integer;
  v_batch_result jsonb;
  v_response jsonb;
BEGIN
  IF p_request_id IS NULL OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_CHECKET_BATCH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND OR v_assignment.station_type <> 'kitchen' THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;

  SELECT count(*)::integer, COALESCE(sum(a.quantity), 0)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', a.item_id, 'queue_id', a.queue_id,
      'source_kind', a.source_kind, 'quantity', a.quantity
    ) ORDER BY a.queue_id, a.source_kind, a.item_id), '[]'::jsonb)
  INTO v_count, v_changed, v_client_snapshot
  FROM jsonb_to_recordset(p_allocations) AS a(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_count > 1000 OR v_changed <= 0 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE a.item_id IS NULL
      OR a.source_kind NOT IN ('base', 'combo_component')
      OR a.quantity IS NULL OR a.quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) GROUP BY a.item_id, a.source_kind HAVING count(*) > 1
  ) THEN RAISE EXCEPTION 'KDS_CHECKET_BATCH_INPUT_INVALID'; END IF;

  -- Preserve the legacy idempotency hash so a durable outbox request created
  -- immediately before deployment can be replayed safely afterwards.
  v_hash := md5(p_allocations::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_assignment.restaurant_id::text || ':kitchen-batch', 0
  ));
  SELECT * INTO v_existing FROM public.emergency_kitchen_batch_actions
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> v_assignment.restaurant_id
       OR v_existing.allocation_hash <> v_hash THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN v_existing.response || jsonb_build_object('deduplicated', true);
  END IF;

  -- A later queue is selectable only when this same request fully consumes
  -- every older pending line with the same localized menu identity.
  IF EXISTS (
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(v_client_snapshot) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), candidates AS (
      SELECT item.id AS item_id, item.queue_id, 'base'::text AS source_kind,
        item.ordered_quantity - item.excused_quantity
          - item.kitchen_done_quantity AS pending,
        lower(btrim(COALESCE(NULLIF(order_item.label, ''),
          NULLIF(order_item.display_name, ''), menu.name_ko, menu.name, '메뉴')))
          AS name_ko,
        lower(btrim(COALESCE(NULLIF(menu.paperless_name_vi, ''),
          NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
          menu.name, 'Món'))) AS name_vi,
        lower(btrim(COALESCE(NULLIF(menu.name_en, ''),
          NULLIF(order_item.display_name, ''), menu.name, 'Item'))) AS name_en,
        queue.created_at, queue.queue_no
      FROM public.emergency_fulfillment_items item
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = item.session_id AND session.status = 'active'
      JOIN public.order_items order_item ON order_item.id = item.order_item_id
      LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
      WHERE item.restaurant_id = v_assignment.restaurant_id
        AND item.is_cancelled = false AND item.needs_review = false
        AND item.kitchen_done_quantity
          < item.ordered_quantity - item.excused_quantity
        AND NOT EXISTS (
          SELECT 1 FROM public.emergency_combo_component_items component
          WHERE component.session_id = item.session_id
            AND component.order_item_id = item.order_item_id
            AND component.is_cancelled = false
        )
      UNION ALL
      SELECT component.id, component.queue_id, 'combo_component',
        component.ordered_quantity - component.excused_quantity
          - component.kitchen_done_quantity,
        lower(btrim(component.name_ko)), lower(btrim(component.name_vi)),
        lower(btrim(component.name_en)), queue.created_at, queue.queue_no
      FROM public.emergency_combo_component_items component
      JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = component.session_id AND session.status = 'active'
      WHERE component.restaurant_id = v_assignment.restaurant_id
        AND component.is_cancelled = false AND component.needs_review = false
        AND component.kitchen_done_quantity
          < component.ordered_quantity - component.excused_quantity
    ), selected AS (
      SELECT candidate.*, allocation.quantity
      FROM candidates candidate
      JOIN allocations allocation
        ON allocation.item_id = candidate.item_id
       AND allocation.source_kind = candidate.source_kind
       AND (allocation.queue_id IS NULL
         OR allocation.queue_id = candidate.queue_id)
    )
    SELECT 1
    FROM selected later
    JOIN candidates earlier
      ON earlier.name_ko = later.name_ko
     AND earlier.name_vi = later.name_vi
     AND earlier.name_en = later.name_en
     AND (earlier.created_at, earlier.queue_no, earlier.queue_id)
       < (later.created_at, later.queue_no, later.queue_id)
    LEFT JOIN allocations earlier_allocation
      ON earlier_allocation.item_id = earlier.item_id
     AND earlier_allocation.source_kind = earlier.source_kind
    WHERE COALESCE(earlier_allocation.quantity, 0) < earlier.pending
  ) THEN
    RAISE EXCEPTION 'KDS_CHECKET_SELECTION_STALE';
  END IF;

  BEGIN
    v_batch_result := public.kds_apply_station_progress_batch_v1(
      p_request_id, v_assignment.restaurant_id, v_user.id,
      'kitchen_done', NULL, v_client_snapshot
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'KDS_BATCH_STALE' THEN
      RAISE EXCEPTION 'KDS_CHECKET_SELECTION_STALE';
    END IF;
    RAISE;
  END;
  v_response := jsonb_build_object(
    'request_id', p_request_id,
    'changed_quantity', (v_batch_result->>'changed_quantity')::integer,
    'event_ids', v_batch_result->'event_ids',
    'deduplicated', false
  );
  INSERT INTO public.emergency_kitchen_batch_actions(
    request_id, restaurant_id, allocation_hash, response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id, v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  p_request_id uuid,
  p_floor_label text,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_existing public.emergency_tray_floor_batch_actions%ROWTYPE;
  v_floor_label text := upper(btrim(COALESCE(p_floor_label, '')));
  v_client_snapshot jsonb;
  v_hash text;
  v_count integer;
  v_changed integer;
  v_batch_result jsonb;
  v_response jsonb;
BEGIN
  IF p_request_id IS NULL OR v_floor_label NOT IN ('1F', '2F')
     OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND OR v_assignment.station_type <> 'tray' THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;

  SELECT count(*)::integer, COALESCE(sum(a.quantity), 0)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', a.item_id, 'queue_id', a.queue_id,
      'source_kind', a.source_kind, 'quantity', a.quantity
    ) ORDER BY a.queue_id, a.source_kind, a.item_id), '[]'::jsonb)
  INTO v_count, v_changed, v_client_snapshot
  FROM jsonb_to_recordset(p_allocations) AS a(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_count > 1000 OR v_changed <= 0 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE a.item_id IS NULL OR a.queue_id IS NULL
      OR a.source_kind NOT IN ('base', 'combo_component')
      OR a.quantity IS NULL OR a.quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) GROUP BY a.item_id, a.source_kind HAVING count(*) > 1
  ) THEN RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_INPUT_INVALID'; END IF;

  v_hash := md5(v_floor_label || ':' || v_client_snapshot::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_assignment.restaurant_id::text || ':tray:' || v_floor_label, 0
  ));
  SELECT * INTO v_existing FROM public.emergency_tray_floor_batch_actions
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> v_assignment.restaurant_id
       OR v_existing.floor_label <> v_floor_label
       OR v_existing.allocation_hash <> v_hash THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN v_existing.response || jsonb_build_object('deduplicated', true);
  END IF;

  BEGIN
    v_batch_result := public.kds_apply_station_progress_batch_v1(
      p_request_id, v_assignment.restaurant_id, v_user.id,
      'tray_dispatched', v_floor_label, v_client_snapshot
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'KDS_BATCH_STALE' THEN
      RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_STALE';
    END IF;
    RAISE;
  END;
  v_response := jsonb_build_object(
    'request_id', p_request_id, 'floor_label', v_floor_label,
    'changed_quantity', (v_batch_result->>'changed_quantity')::integer,
    'event_ids', v_batch_result->'event_ids', 'deduplicated', false
  );
  INSERT INTO public.emergency_tray_floor_batch_actions(
    request_id, restaurant_id, floor_label, allocation_hash,
    response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id, v_floor_label,
    v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.kds_complete_customer_delivery_batch_v1(
  p_request_id uuid,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_existing public.emergency_customer_delivery_batch_actions%ROWTYPE;
  v_floor_label text;
  v_client_snapshot jsonb;
  v_hash text;
  v_count integer;
  v_changed integer;
  v_batch_result jsonb;
  v_response jsonb;
BEGIN
  IF p_request_id IS NULL OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND OR v_assignment.station_type <> 'floor'
     OR v_assignment.floor_label IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;
  v_floor_label := upper(btrim(v_assignment.floor_label));

  SELECT count(*)::integer, COALESCE(sum(a.quantity), 0)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', a.item_id, 'queue_id', a.queue_id,
      'source_kind', a.source_kind, 'quantity', a.quantity
    ) ORDER BY a.queue_id, a.source_kind, a.item_id), '[]'::jsonb)
  INTO v_count, v_changed, v_client_snapshot
  FROM jsonb_to_recordset(p_allocations) AS a(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_count > 1000 OR v_changed <= 0 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE a.item_id IS NULL OR a.queue_id IS NULL
      OR a.source_kind NOT IN ('base', 'combo_component')
      OR a.quantity IS NULL OR a.quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) GROUP BY a.item_id, a.source_kind HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_INPUT_INVALID';
  END IF;

  v_hash := md5(v_floor_label || ':' || v_client_snapshot::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_assignment.restaurant_id::text || ':floor:' || v_floor_label, 0
  ));
  SELECT * INTO v_existing
  FROM public.emergency_customer_delivery_batch_actions
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> v_assignment.restaurant_id
       OR upper(btrim(v_existing.floor_label)) <> v_floor_label
       OR v_existing.allocation_hash <> v_hash THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN v_existing.response || jsonb_build_object('deduplicated', true);
  END IF;

  BEGIN
    v_batch_result := public.kds_apply_station_progress_batch_v1(
      p_request_id, v_assignment.restaurant_id, v_user.id,
      'floor_served', v_floor_label, v_client_snapshot
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'KDS_BATCH_STALE' THEN
      RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_STALE';
    END IF;
    RAISE;
  END;
  v_response := jsonb_build_object(
    'request_id', p_request_id, 'floor_label', v_floor_label,
    'changed_quantity', (v_batch_result->>'changed_quantity')::integer,
    'event_ids', v_batch_result->'event_ids', 'deduplicated', false
  );
  INSERT INTO public.emergency_customer_delivery_batch_actions(
    request_id, restaurant_id, floor_label, allocation_hash,
    response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id, v_floor_label,
    v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
) TO authenticated;

-- The legacy client subscribes to both ledgers. Missing either table makes
-- Realtime reject the complete channel and forces the 30-second health poll.
DO $publication$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_actions'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.emergency_fulfillment_actions;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.emergency_fulfillment_events;
  END IF;
END;
$publication$;

DO $verify$
DECLARE
  v_name text;
  v_definition text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
    'public.kds_complete_kitchen_batch_v1(uuid,jsonb)',
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
    'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
  ] LOOP
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
    IF v_definition ~* '\m(loop|foreach)\M'
       OR position('kds_record_station_progress_v3(' IN v_definition) > 0
       OR position('kds_record_progress_v2(' IN v_definition) > 0 THEN
      RAISE EXCEPTION 'KDS_SET_BASED_FUNCTION_VERIFY_FAILED: %', v_name;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_actions'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_events'
  ) THEN
    RAISE EXCEPTION 'KDS_REALTIME_PUBLICATION_VERIFY_FAILED';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated',
       'public.kds_complete_kitchen_batch_v1(uuid,jsonb)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated',
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_SET_BASED_PRIVILEGE_VERIFY_FAILED';
  END IF;
END;
$verify$;

COMMIT;
