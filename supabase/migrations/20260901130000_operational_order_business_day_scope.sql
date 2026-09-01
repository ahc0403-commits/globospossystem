BEGIN;

-- Operational order boards are scoped to the current Vietnam civil day even
-- when an authenticated device or paperless session remains open overnight.
-- Historical data is retained for reporting, receipts, and audit workflows.

CREATE INDEX IF NOT EXISTS orders_store_status_created_id
  ON public.orders (restaurant_id, status, created_at, id);

CREATE INDEX IF NOT EXISTS emergency_queue_session_created_queue
  ON public.emergency_order_queue (session_id, created_at, queue_no);

-- This is the innermost snapshot function. Apply the business-day predicate
-- before item aggregation so a long-running emergency session cannot rebuild
-- every historical ticket on each KDS refresh.
CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot_base()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'assigned', false, 'active', false,
      'restaurant_id', v_user.restaurant_id, 'orders', '[]'::jsonb
    );
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = v_assignment.restaurant_id AND status = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'assigned', true, 'active', false,
      'restaurant_id', v_assignment.restaurant_id,
      'station_type', v_assignment.station_type,
      'floor_label', v_assignment.floor_label,
      'orders', '[]'::jsonb
    );
  END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  SELECT COALESCE(jsonb_agg(order_payload ORDER BY queue_no), '[]'::jsonb)
  INTO v_orders
  FROM (
    SELECT queue.queue_no,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'last_action_id', recent.action_id,
        'last_action_at', recent.created_at,
        'items', COALESCE((
          SELECT jsonb_agg(
            item_payload ORDER BY created_at, order_item_id, line_key
          )
          FROM (
            SELECT
              fulfillment.created_at,
              fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM public.emergency_fulfillment_items fulfillment
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT
              direct.created_at,
              direct.order_item_id,
              direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM public.emergency_floor_direct_items direct
            WHERE direct.queue_id = queue.id
              AND direct.is_cancelled = false
          ) station_items
        ), '[]'::jsonb)
      ) AS order_payload
    FROM public.emergency_order_queue queue
    LEFT JOIN LATERAL (
      SELECT action.action_id, action.created_at
      FROM public.emergency_fulfillment_actions action
      WHERE action.queue_id = queue.id
        AND action.station_type = v_assignment.station_type
        AND action.action_kind = 'complete'
        AND NOT EXISTS (
          SELECT 1
          FROM public.emergency_fulfillment_actions reversal
          WHERE reversal.original_action_id = action.action_id
            AND reversal.action_kind = 'revert'
        )
      ORDER BY action.created_at DESC, action.action_id DESC
      LIMIT 1
    ) recent ON true
    WHERE queue.session_id = v_session.id
      AND queue.created_at >= v_day_start
      AND queue.created_at < v_day_end
      AND (
        v_assignment.station_type <> 'floor'
        OR queue.floor_label = v_assignment.floor_label
      )
  ) rows;

  RETURN jsonb_build_object(
    'assigned', true, 'active', true,
    'session_id', v_session.id,
    'restaurant_id', v_assignment.restaurant_id,
    'station_type', v_assignment.station_type,
    'floor_label', v_assignment.floor_label,
    'activated_at', v_session.activated_at,
    'orders', v_orders
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_base()
  FROM PUBLIC, anon, authenticated;

-- The auxiliary timing payload must not rescan every queue in an active
-- multi-day session after the main snapshot has already been narrowed.
CREATE OR REPLACE FUNCTION public.get_emergency_station_timings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_timings jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'queue_id', queue.id,
        'station_started_at', CASE v_assignment.station_type
          WHEN 'kitchen' THEN queue.created_at
          WHEN 'tray' THEN station_events.previous_stage_at
          ELSE CASE
            WHEN EXISTS (
              SELECT 1
              FROM public.emergency_floor_direct_items direct
              WHERE direct.session_id = queue.session_id
                AND direct.order_id = queue.order_id
                AND direct.queue_id = queue.id
                AND direct.is_cancelled = false
            ) THEN queue.created_at
            ELSE station_events.previous_stage_at
          END
        END,
        'station_completed_at', station_events.completed_at
      )
      ORDER BY queue.queue_no
    ),
    '[]'::jsonb
  )
  INTO v_timings
  FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id
  LEFT JOIN LATERAL (
    SELECT
      min(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'tray' THEN 'kitchen_done'
          WHEN 'floor' THEN 'tray_dispatched'
          ELSE 'order_received'
        END
      ) AS previous_stage_at,
      max(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'kitchen' THEN 'kitchen_done'
          WHEN 'tray' THEN 'tray_dispatched'
          ELSE 'floor_served'
        END
      ) AS completed_at
    FROM public.emergency_fulfillment_events event
    WHERE event.restaurant_id = queue.restaurant_id
      AND event.session_id = queue.session_id
      AND event.order_id = queue.order_id
      AND event.delta > 0
      AND event.stage IN (
        'order_received', 'kitchen_done', 'tray_dispatched', 'floor_served'
      )
  ) station_events ON true
  WHERE queue.restaurant_id = v_assignment.restaurant_id
    AND queue.created_at >= v_day_start
    AND queue.created_at < v_day_end
    AND (
      v_assignment.station_type <> 'floor'
      OR queue.floor_label = v_assignment.floor_label
    )
    AND (
      session.status = 'active'
      OR (
        station_events.completed_at >= v_day_start
        AND station_events.completed_at < v_day_end
      )
    );

  RETURN v_timings;
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_timings()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_timings()
  TO authenticated;

-- Preserve all established snapshot enrichments, then fail closed around any
-- additive payload that is not produced by the date-scoped base function.
ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_pre_business_day;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_business_day()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders jsonb := '[]'::jsonb;
  v_tasks jsonb := '[]'::jsonb;
BEGIN
  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';
  v_payload := public.get_emergency_station_snapshot_pre_business_day();

  SELECT COALESCE(jsonb_agg(entry.raw ORDER BY entry.ord), '[]'::jsonb)
  INTO v_orders
  FROM jsonb_array_elements(COALESCE(v_payload->'orders', '[]'::jsonb))
    WITH ORDINALITY entry(raw, ord)
  WHERE NULLIF(entry.raw->>'created_at', '')::timestamptz >= v_day_start
    AND NULLIF(entry.raw->>'created_at', '')::timestamptz < v_day_end;

  SELECT COALESCE(jsonb_agg(entry.raw ORDER BY entry.ord), '[]'::jsonb)
  INTO v_tasks
  FROM jsonb_array_elements(
    COALESCE(v_payload->'leftover_packaging_tasks', '[]'::jsonb)
  ) WITH ORDINALITY entry(raw, ord)
  WHERE NULLIF(entry.raw->>'requested_at', '')::timestamptz >= v_day_start
    AND NULLIF(entry.raw->>'requested_at', '')::timestamptz < v_day_end;

  RETURN jsonb_set(
    jsonb_set(COALESCE(v_payload, '{}'::jsonb), '{orders}', v_orders, true),
    '{leftover_packaging_tasks}', v_tasks, true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;

ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_pre_business_day;

REVOKE ALL ON FUNCTION
  public.get_emergency_station_today_completed_pre_business_day()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_rows jsonb;
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';
  v_rows := public.get_emergency_station_today_completed_pre_business_day();

  RETURN COALESCE((
    SELECT jsonb_agg(entry.raw ORDER BY entry.ord)
    FROM jsonb_array_elements(COALESCE(v_rows, '[]'::jsonb))
      WITH ORDINALITY entry(raw, ord)
    WHERE NULLIF(entry.raw->>'created_at', '')::timestamptz >= v_day_start
      AND NULLIF(entry.raw->>'created_at', '')::timestamptz < v_day_end
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

-- Active KDS v2 receives single-ticket invalidations outside the bootstrap
-- path. Keep an old-day update from reintroducing a historical card.
ALTER FUNCTION public.get_kds_ticket_v2(uuid)
  RENAME TO get_kds_ticket_v2_pre_business_day;

REVOKE ALL ON FUNCTION public.get_kds_ticket_v2_pre_business_day(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_ticket_v2(p_queue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_ticket jsonb;
  v_created_at timestamptz;
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  v_result := public.get_kds_ticket_v2_pre_business_day(p_queue_id);
  v_ticket := NULLIF(v_result->'ticket', 'null'::jsonb);
  IF v_ticket IS NULL THEN RETURN v_result; END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';
  v_created_at := NULLIF(v_ticket->>'created_at', '')::timestamptz;

  IF v_created_at IS NULL
     OR v_created_at < v_day_start
     OR v_created_at >= v_day_end THEN
    RETURN jsonb_set(v_result, '{ticket}', 'null'::jsonb, true);
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_ticket_v2(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_ticket_v2(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.search_active_order_for_cashier(
  p_store_id uuid,
  p_query text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_query text := lower(replace(btrim(COALESCE(p_query, '')), '#', ''));
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL OR v_query = '' THEN RETURN NULL; END IF;

  IF NOT (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) store_access(store_id)
      WHERE store_access.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_DENIED';
  END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  SELECT jsonb_build_object(
    'id', order_row.id::text,
    'table_id', order_row.table_id::text,
    'status', order_row.status,
    'order_purpose', order_row.order_purpose,
    'order_source', order_row.order_source,
    'created_at', order_row.created_at,
    'tables', jsonb_build_object(
      'table_number',
      CASE
        WHEN order_row.order_purpose = 'staff_meal' THEN 'STAFF'
        ELSE COALESCE(table_row.table_number, '-')
      END
    )
  )
  INTO v_result
  FROM public.orders order_row
  LEFT JOIN public.tables table_row
    ON table_row.id = order_row.table_id
   AND table_row.restaurant_id = order_row.restaurant_id
  WHERE order_row.restaurant_id = p_store_id
    AND order_row.status IN ('pending', 'confirmed', 'serving')
    AND order_row.created_at >= v_day_start
    AND order_row.created_at < v_day_end
    AND (
      lower(substring(order_row.id::text from 1 for 8)) = v_query
      OR lower(order_row.id::text) LIKE v_query || '%'
      OR lower(COALESCE(table_row.table_number, '')) = v_query
      OR lower(COALESCE(table_row.table_number, '')) LIKE '%' || v_query || '%'
    )
  ORDER BY
    CASE
      WHEN lower(substring(order_row.id::text from 1 for 8)) = v_query THEN 0
      WHEN lower(COALESCE(table_row.table_number, '')) = v_query THEN 1
      WHEN lower(order_row.id::text) LIKE v_query || '%' THEN 2
      ELSE 3
    END,
    order_row.created_at DESC
  LIMIT 1;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.search_active_order_for_cashier(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_active_order_for_cashier(uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_list(
  p_store_id uuid,
  p_states text[] DEFAULT NULL,
  p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  RETURN COALESCE((
    SELECT jsonb_agg(row_payload ORDER BY created_at DESC, id DESC)
    FROM (
      SELECT
        request_row.created_at,
        request_row.id,
        jsonb_build_object(
          'id', request_row.id,
          'reference_code', request_row.reference_code,
          'state', request_row.state,
          'created_at', request_row.created_at,
          'customer_name', address.customer_name,
          'formatted_address', address.formatted_address,
          'district', address.district,
          'item_count', (
            SELECT COALESCE(sum(item.quantity), 0)
            FROM public.direct_order_request_items item
            WHERE item.request_id = request_row.id
          ),
          'final_total', quote_row.final_total,
          'has_payment_proof', EXISTS (
            SELECT 1 FROM public.direct_order_messages message
            WHERE message.request_id = request_row.id
              AND message.message_type = 'payment_proof'
          ),
          'last_message_at', (
            SELECT max(message.created_at)
            FROM public.direct_order_messages message
            WHERE message.request_id = request_row.id
          )
        ) AS row_payload
      FROM public.direct_order_requests request_row
      LEFT JOIN public.direct_order_request_addresses address
        ON address.request_id = request_row.id
      LEFT JOIN LATERAL (
        SELECT quote.final_total
        FROM public.direct_order_quotes quote
        WHERE quote.request_id = request_row.id
          AND quote.status IN ('active', 'locked')
        ORDER BY quote.version DESC LIMIT 1
      ) quote_row ON true
      WHERE request_row.restaurant_id = p_store_id
        AND request_row.created_at >= v_day_start
        AND request_row.created_at < v_day_end
        AND (p_states IS NULL OR request_row.state = ANY(p_states))
        AND (
          p_after_created_at IS NULL
          OR (request_row.created_at, request_row.id)
             < (p_after_created_at, p_after_id)
        )
      ORDER BY request_row.created_at DESC, request_row.id DESC
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_list(
  uuid, text[], timestamptz, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list(
  uuid, text[], timestamptz, uuid, integer
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_list(
  p_store_id uuid,
  p_statuses text[] DEFAULT NULL,
  p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['kitchen', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  RETURN COALESCE((
    SELECT jsonb_agg(payload ORDER BY created_at, id)
    FROM (
      SELECT ticket.created_at, ticket.id, jsonb_build_object(
        'id', ticket.id,
        'request_id', ticket.request_id,
        'status', ticket.status,
        'pickup_code', ticket.pickup_code,
        'version', ticket.version,
        'created_at', ticket.created_at,
        'updated_at', ticket.updated_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', item.id,
            'name_ko', item.display_name_ko,
            'name_vi', item.display_name_vi,
            'name_en', item.display_name_en,
            'quantity', item.quantity,
            'note', item.item_note
          ) ORDER BY item.sort_order, item.id)
          FROM public.direct_delivery_fulfillment_ticket_items item
          WHERE item.ticket_id = ticket.id
        ), '[]'::jsonb)
      ) AS payload
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.restaurant_id = p_store_id
        AND ticket.created_at >= v_day_start
        AND ticket.created_at < v_day_end
        AND (p_statuses IS NULL OR ticket.status = ANY(p_statuses))
        AND (
          p_after_created_at IS NULL
          OR (ticket.created_at, ticket.id)
             > (p_after_created_at, p_after_id)
        )
      ORDER BY ticket.created_at, ticket.id
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list(
  uuid, text[], timestamptz, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list(
  uuid, text[], timestamptz, uuid, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_emergency_station_snapshot() IS
  'Returns only orders created during the current Asia/Ho_Chi_Minh civil day; authentication and station assignment remain session-independent.';
COMMENT ON FUNCTION public.search_active_order_for_cashier(uuid, text) IS
  'Searches active cashier orders created during the current Asia/Ho_Chi_Minh civil day.';
COMMENT ON FUNCTION public.direct_order_staff_list(
  uuid, text[], timestamptz, uuid, integer
) IS 'Lists direct-order requests created during the current Asia/Ho_Chi_Minh civil day.';
COMMENT ON FUNCTION public.direct_delivery_ticket_list(
  uuid, text[], timestamptz, uuid, integer
) IS 'Lists direct-delivery kitchen tickets created during the current Asia/Ho_Chi_Minh civil day.';

-- production-gate: self-verifying
DO $verify$
DECLARE
  v_snapshot_definition text;
  v_timing_definition text;
  v_ticket_definition text;
  v_cashier_definition text;
  v_direct_list_definition text;
  v_direct_ticket_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_emergency_station_snapshot_base()'::regprocedure
  ) INTO v_snapshot_definition;
  SELECT pg_get_functiondef(
    'public.get_emergency_station_timings()'::regprocedure
  ) INTO v_timing_definition;
  SELECT pg_get_functiondef(
    'public.get_kds_ticket_v2(uuid)'::regprocedure
  ) INTO v_ticket_definition;
  SELECT pg_get_functiondef(
    'public.search_active_order_for_cashier(uuid,text)'::regprocedure
  ) INTO v_cashier_definition;
  SELECT pg_get_functiondef(
    'public.direct_order_staff_list(uuid,text[],timestamp with time zone,uuid,integer)'::regprocedure
  ) INTO v_direct_list_definition;
  SELECT pg_get_functiondef(
    'public.direct_delivery_ticket_list(uuid,text[],timestamp with time zone,uuid,integer)'::regprocedure
  ) INTO v_direct_ticket_definition;

  IF position('Asia/Ho_Chi_Minh' IN v_snapshot_definition) = 0
     OR position('queue.created_at >= v_day_start' IN v_snapshot_definition) = 0
     OR position('queue.created_at < v_day_end' IN v_snapshot_definition) = 0
     OR position('queue.created_at >= v_day_start' IN v_timing_definition) = 0
     OR position('get_kds_ticket_v2_pre_business_day' IN v_ticket_definition) = 0
     OR position('created_at >= v_day_start' IN v_cashier_definition) = 0
     OR position('request_row.created_at >= v_day_start' IN v_direct_list_definition) = 0
     OR position('ticket.created_at >= v_day_start' IN v_direct_ticket_definition) = 0 THEN
    RAISE EXCEPTION 'OPERATIONAL_BUSINESS_DAY_SCOPE_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'orders_store_status_created_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'emergency_queue_session_created_queue'
  ) THEN
    RAISE EXCEPTION 'OPERATIONAL_BUSINESS_DAY_INDEX_VERIFICATION_FAILED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated', 'public.get_emergency_station_snapshot()', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated', 'public.get_kds_ticket_v2(uuid)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.search_active_order_for_cashier(uuid,text)', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon', 'public.get_emergency_station_snapshot()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'OPERATIONAL_BUSINESS_DAY_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
