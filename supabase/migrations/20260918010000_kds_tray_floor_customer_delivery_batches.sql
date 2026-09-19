BEGIN;

-- production-gate: self-verifying

CREATE TABLE public.emergency_tray_floor_batch_actions (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  floor_label text NOT NULL CHECK (floor_label IN ('1F', '2F')),
  allocation_hash text NOT NULL,
  response jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emergency_customer_delivery_batch_actions (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  floor_label text NOT NULL,
  allocation_hash text NOT NULL,
  response jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.emergency_tray_floor_batch_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_customer_delivery_batch_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.emergency_tray_floor_batch_actions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_customer_delivery_batch_actions
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.emergency_tray_floor_batch_actions TO service_role;
GRANT ALL ON public.emergency_customer_delivery_batch_actions TO service_role;

CREATE INDEX emergency_tray_floor_batch_actions_restaurant_created_idx
  ON public.emergency_tray_floor_batch_actions (restaurant_id, created_at);
CREATE INDEX emergency_tray_floor_batch_actions_created_by_idx
  ON public.emergency_tray_floor_batch_actions (created_by);
CREATE INDEX emergency_customer_delivery_batch_actions_restaurant_created_idx
  ON public.emergency_customer_delivery_batch_actions (
    restaurant_id,
    created_at
  );
CREATE INDEX emergency_customer_delivery_batch_actions_created_by_idx
  ON public.emergency_customer_delivery_batch_actions (created_by);

-- A tray acknowledgement is an exact floor snapshot. Locking the tray-ready
-- sequence prevents a kitchen completion from entering the snapshot between
-- validation and dispatch.
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
  v_server_snapshot jsonb;
  v_hash text;
  v_count integer;
  v_changed integer;
  v_allocation record;
  v_index integer;
  v_event_id uuid;
  v_event_ids jsonb := '[]'::jsonb;
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

  SELECT count(*)::integer, COALESCE(sum(x.quantity), 0)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', x.item_id,
      'queue_id', x.queue_id,
      'source_kind', x.source_kind,
      'quantity', x.quantity
    ) ORDER BY x.queue_id, x.source_kind, x.item_id), '[]'::jsonb)
  INTO v_count, v_changed, v_client_snapshot
  FROM jsonb_to_recordset(p_allocations) AS x(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_count > 1000 OR v_changed <= 0 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS x(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE x.item_id IS NULL OR x.queue_id IS NULL
      OR x.source_kind NOT IN ('base', 'combo_component')
      OR x.quantity IS NULL OR x.quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS x(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    GROUP BY x.item_id, x.source_kind HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_INPUT_INVALID';
  END IF;

  v_hash := md5(v_floor_label || ':' || v_client_snapshot::text);
  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_assignment.restaurant_id::text || ':tray:' || v_floor_label, 0)
  );
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

  -- Lock the client snapshot lines in the same item -> sequence order used by
  -- kitchen progress. Unrelated new kitchen completions may finish before this
  -- barrier (and make the exact snapshot stale) or wait behind it (and remain
  -- pending for the next batch), but cannot be included silently.
  BEGIN
    PERFORM 1
    FROM public.emergency_combo_component_items component
    JOIN jsonb_to_recordset(v_client_snapshot) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = component.id
      AND allocation.queue_id = component.queue_id
      AND allocation.source_kind = 'combo_component'
    JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    WHERE component.restaurant_id = v_assignment.restaurant_id
      AND upper(btrim(queue.floor_label)) = v_floor_label
    ORDER BY component.id
    FOR UPDATE OF component, queue NOWAIT;

    PERFORM 1
    FROM public.emergency_fulfillment_items item
    JOIN jsonb_to_recordset(v_client_snapshot) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = item.id
      AND allocation.queue_id = item.queue_id
      AND allocation.source_kind = 'base'
    JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
    WHERE item.restaurant_id = v_assignment.restaurant_id
      AND upper(btrim(queue.floor_label)) = v_floor_label
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )
    ORDER BY item.id
    FOR UPDATE OF item, queue NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_STALE';
  END;

  -- Kitchen completion increments this row before publishing a ready lot.
  PERFORM 1 FROM public.emergency_tray_ready_sequences sequence
  WHERE sequence.restaurant_id = v_assignment.restaurant_id FOR UPDATE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', current_line.item_id,
    'queue_id', current_line.queue_id,
    'source_kind', current_line.source_kind,
    'quantity', current_line.quantity
  ) ORDER BY current_line.queue_id, current_line.source_kind, current_line.item_id), '[]'::jsonb)
  INTO v_server_snapshot
  FROM (
    SELECT item.id AS item_id, queue.id AS queue_id, 'base'::text AS source_kind,
      item.kitchen_done_quantity - item.tray_dispatched_quantity AS quantity
    FROM public.emergency_fulfillment_items item
    JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = queue.order_id
    WHERE item.restaurant_id = v_assignment.restaurant_id
      AND upper(btrim(queue.floor_label)) = v_floor_label
      AND queue.workflow_version = 2
      AND COALESCE(order_row.sales_channel, 'dine_in') <> 'delivery'
      AND item.is_cancelled = false AND item.needs_review = false
      AND item.kitchen_done_quantity > item.tray_dispatched_quantity
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )
    UNION ALL
    SELECT component.id, queue.id, 'combo_component',
      component.kitchen_done_quantity - component.tray_dispatched_quantity
    FROM public.emergency_combo_component_items component
    JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = component.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = queue.order_id
    WHERE component.restaurant_id = v_assignment.restaurant_id
      AND upper(btrim(queue.floor_label)) = v_floor_label
      AND queue.workflow_version = 2
      AND COALESCE(order_row.sales_channel, 'dine_in') <> 'delivery'
      AND component.is_cancelled = false AND component.needs_review = false
      AND component.kitchen_done_quantity > component.tray_dispatched_quantity
  ) current_line;

  IF v_server_snapshot <> v_client_snapshot THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_STALE';
  END IF;

  FOR v_allocation IN
    SELECT x.item_id, x.queue_id, x.source_kind, x.quantity
    FROM jsonb_to_recordset(v_client_snapshot) AS x(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ORDER BY x.queue_id, x.source_kind, x.item_id
  LOOP
    FOR v_index IN 1..v_allocation.quantity LOOP
      v_event_id := gen_random_uuid();
      PERFORM public.kds_record_station_progress_v3(
        v_allocation.item_id, v_allocation.source_kind,
        'tray_dispatched', 1, v_event_id
      );
      v_event_ids := v_event_ids || jsonb_build_array(v_event_id);
    END LOOP;
  END LOOP;

  v_response := jsonb_build_object(
    'request_id', p_request_id,
    'floor_label', v_floor_label,
    'changed_quantity', v_changed,
    'event_ids', v_event_ids,
    'deduplicated', false
  );
  INSERT INTO public.emergency_tray_floor_batch_actions (
    request_id, restaurant_id, floor_label, allocation_hash, response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id, v_floor_label,
    v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
) TO authenticated;

-- Customer delivery accepts an explicit subset. New tray arrivals remain
-- pending, while any selected line whose quantity shrank rejects the whole
-- transaction.
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
  v_client_snapshot jsonb;
  v_hash text;
  v_count integer;
  v_changed integer;
  v_allocation record;
  v_item record;
  v_index integer;
  v_event_id uuid;
  v_event_ids jsonb := '[]'::jsonb;
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

  SELECT count(*)::integer, COALESCE(sum(x.quantity), 0)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', x.item_id,
      'queue_id', x.queue_id,
      'source_kind', x.source_kind,
      'quantity', x.quantity
    ) ORDER BY x.queue_id, x.source_kind, x.item_id), '[]'::jsonb)
  INTO v_count, v_changed, v_client_snapshot
  FROM jsonb_to_recordset(p_allocations) AS x(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_count > 1000 OR v_changed <= 0 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS x(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE x.item_id IS NULL OR x.queue_id IS NULL
      OR x.source_kind NOT IN ('base', 'combo_component')
      OR x.quantity IS NULL OR x.quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_allocations) AS x(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    GROUP BY x.item_id, x.source_kind HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_INPUT_INVALID';
  END IF;

  v_hash := md5(
    upper(btrim(v_assignment.floor_label)) || ':' || v_client_snapshot::text
  );
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_assignment.restaurant_id::text || ':floor:' ||
      upper(btrim(v_assignment.floor_label)), 0
  ));
  SELECT * INTO v_existing
  FROM public.emergency_customer_delivery_batch_actions
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> v_assignment.restaurant_id
       OR upper(btrim(v_existing.floor_label))
          <> upper(btrim(v_assignment.floor_label))
       OR v_existing.allocation_hash <> v_hash THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN v_existing.response || jsonb_build_object('deduplicated', true);
  END IF;

  BEGIN
    FOR v_allocation IN
      SELECT x.item_id, x.queue_id, x.source_kind, x.quantity
      FROM jsonb_to_recordset(v_client_snapshot) AS x(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      ) ORDER BY x.queue_id, x.source_kind, x.item_id
    LOOP
      v_item := NULL;
      IF v_allocation.source_kind = 'combo_component' THEN
        SELECT component.id, component.queue_id,
          component.tray_dispatched_quantity - component.floor_served_quantity
            AS pending
        INTO v_item
        FROM public.emergency_combo_component_items component
        JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
        JOIN public.emergency_fulfillment_sessions session
          ON session.id = component.session_id AND session.status = 'active'
        JOIN public.orders order_row ON order_row.id = queue.order_id
        WHERE component.id = v_allocation.item_id
          AND component.restaurant_id = v_assignment.restaurant_id
          AND component.queue_id = v_allocation.queue_id
          AND upper(btrim(queue.floor_label))
            = upper(btrim(v_assignment.floor_label))
          AND queue.workflow_version = 2
          AND COALESCE(order_row.sales_channel, 'dine_in') <> 'delivery'
          AND component.is_cancelled = false AND component.needs_review = false
        FOR UPDATE OF component, queue NOWAIT;
      ELSE
        SELECT item.id, item.queue_id,
          item.tray_dispatched_quantity - item.floor_served_quantity AS pending
        INTO v_item
        FROM public.emergency_fulfillment_items item
        JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
        JOIN public.emergency_fulfillment_sessions session
          ON session.id = item.session_id AND session.status = 'active'
        JOIN public.orders order_row ON order_row.id = queue.order_id
        WHERE item.id = v_allocation.item_id
          AND item.restaurant_id = v_assignment.restaurant_id
          AND item.queue_id = v_allocation.queue_id
          AND upper(btrim(queue.floor_label))
            = upper(btrim(v_assignment.floor_label))
          AND queue.workflow_version = 2
          AND COALESCE(order_row.sales_channel, 'dine_in') <> 'delivery'
          AND item.is_cancelled = false AND item.needs_review = false
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_combo_component_items component
            WHERE component.session_id = item.session_id
              AND component.order_item_id = item.order_item_id
              AND component.is_cancelled = false
          )
        FOR UPDATE OF item, queue NOWAIT;
      END IF;
      IF v_item.id IS NULL OR v_item.pending < v_allocation.quantity THEN
        RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_STALE';
      END IF;

      FOR v_index IN 1..v_allocation.quantity LOOP
        v_event_id := gen_random_uuid();
        PERFORM public.kds_record_station_progress_v3(
          v_allocation.item_id, v_allocation.source_kind,
          'floor_served', 1, v_event_id
        );
        v_event_ids := v_event_ids || jsonb_build_array(v_event_id);
      END LOOP;
    END LOOP;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_BATCH_STALE';
  END;

  v_response := jsonb_build_object(
    'request_id', p_request_id,
    'floor_label', upper(btrim(v_assignment.floor_label)),
    'changed_quantity', v_changed,
    'event_ids', v_event_ids,
    'deduplicated', false
  );
  INSERT INTO public.emergency_customer_delivery_batch_actions (
    request_id, restaurant_id, floor_label, allocation_hash, response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id,
    upper(btrim(v_assignment.floor_label)), v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
) TO authenticated;

DO $$
BEGIN
  IF to_regclass('public.emergency_tray_floor_batch_actions') IS NULL
     OR to_regclass('public.emergency_customer_delivery_batch_actions') IS NULL
     OR to_regclass(
       'public.emergency_tray_floor_batch_actions_restaurant_created_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_tray_floor_batch_actions_created_by_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions_restaurant_created_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions_created_by_idx'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_SELF_VERIFY_FAILED';
  END IF;
END;
$$;

COMMIT;
