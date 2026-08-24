BEGIN;

-- production-gate: self-verifying

-- Base order-item events are read by immutable order_item_id when the live KDS
-- response is enriched with per-batch timing boundaries. Combo and floor-direct
-- ledgers already have their own item-specific indexes.
CREATE INDEX IF NOT EXISTS emergency_events_order_item_stage_created
  ON public.emergency_fulfillment_events (order_item_id, stage, created_at)
  WHERE order_item_id IS NOT NULL AND delta > 0;

-- Add immutable batch arrival and station event boundaries to every item in an
-- already-authorized paperless response. A single QR/add-items submission runs
-- in one transaction, so all of its order_items share the same created_at and
-- form one stable batch without changing the established order/payment model.
CREATE OR REPLACE FUNCTION public.emergency_add_order_batch_timings(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
  SELECT COALESCE(jsonb_agg(
    order_row.raw || jsonb_build_object(
      'items', COALESCE((
        SELECT jsonb_agg(
          item_row.raw || jsonb_strip_nulls(jsonb_build_object(
            'batch_received_at', order_item.created_at,
            'kitchen_first_done_at', event_times.kitchen_first_done_at,
            'kitchen_last_done_at', event_times.kitchen_last_done_at,
            'tray_first_dispatched_at', event_times.tray_first_dispatched_at,
            'tray_last_dispatched_at', event_times.tray_last_dispatched_at,
            'floor_first_served_at', event_times.floor_first_served_at,
            'floor_last_served_at', event_times.floor_last_served_at
          ))
          ORDER BY item_row.ord
        )
        FROM jsonb_array_elements(COALESCE(order_row.raw->'items', '[]'::jsonb))
          WITH ORDINALITY item_row(raw, ord)
        LEFT JOIN public.order_items order_item
          ON order_item.id = CASE
            WHEN item_row.raw->>'order_item_id' ~*
              '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN (item_row.raw->>'order_item_id')::uuid
            ELSE NULL
          END
        LEFT JOIN LATERAL (
          SELECT
            min(event.created_at) FILTER (
              WHERE event.stage = 'kitchen_done'
            ) AS kitchen_first_done_at,
            max(event.created_at) FILTER (
              WHERE event.stage = 'kitchen_done'
            ) AS kitchen_last_done_at,
            min(event.created_at) FILTER (
              WHERE event.stage = 'tray_dispatched'
            ) AS tray_first_dispatched_at,
            max(event.created_at) FILTER (
              WHERE event.stage = 'tray_dispatched'
            ) AS tray_last_dispatched_at,
            min(event.created_at) FILTER (
              WHERE event.stage = 'floor_served'
            ) AS floor_first_served_at,
            max(event.created_at) FILTER (
              WHERE event.stage = 'floor_served'
            ) AS floor_last_served_at
          FROM public.emergency_fulfillment_events event
          WHERE event.delta > 0
            AND (
              (
                item_row.raw->>'source_kind' = 'combo_component'
                AND event.combo_component_item_id = CASE
                  WHEN item_row.raw->>'id' ~*
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  THEN (item_row.raw->>'id')::uuid
                  ELSE NULL
                END
              )
              OR (
                item_row.raw->>'fulfillment_route' = 'floor_direct'
                AND event.floor_direct_item_id = CASE
                  WHEN item_row.raw->>'id' ~*
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  THEN (item_row.raw->>'id')::uuid
                  ELSE NULL
                END
              )
              OR (
                COALESCE(item_row.raw->>'source_kind', 'order_item')
                  <> 'combo_component'
                AND COALESCE(item_row.raw->>'fulfillment_route',
                  'kitchen_tray_floor') <> 'floor_direct'
                AND event.order_item_id = order_item.id
                AND event.combo_component_item_id IS NULL
                AND event.floor_direct_item_id IS NULL
              )
            )
        ) event_times ON true
      ), '[]'::jsonb)
    )
    ORDER BY order_row.ord
  ), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_orders, '[]'::jsonb))
    WITH ORDINALITY order_row(raw, ord);
$$;

REVOKE ALL ON FUNCTION public.emergency_add_order_batch_timings(jsonb)
  FROM PUBLIC, anon, authenticated;

-- Preserve every established snapshot wrapper (localization, combo progress,
-- takeout flags, and leftover tasks) and enrich only its final order payload.
ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_pre_batch_timing;
ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_pre_batch_timing;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_batch_timing()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed_pre_batch_timing()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := public.get_emergency_station_snapshot_pre_batch_timing();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(
      v_payload,
      '{orders}',
      public.emergency_add_order_batch_timings(v_payload->'orders'),
      true
    );
  END IF;
  RETURN v_payload;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  RETURN public.emergency_add_order_batch_timings(
    public.get_emergency_station_today_completed_pre_batch_timing()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

-- Keep the established report as the authority for authorization, range
-- validation, station metrics, and menu metrics. Override only dining time so
-- it starts at the first served menu and therefore includes time spent eating
-- while later supplemental batches are prepared and delivered.
ALTER FUNCTION public.get_paperless_operations_report(
  uuid, timestamptz, timestamptz
) RENAME TO get_paperless_operations_report_pre_meal_start;

REVOKE ALL ON FUNCTION public.get_paperless_operations_report_pre_meal_start(
  uuid, timestamptz, timestamptz
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_paperless_operations_report(
  p_store_id uuid,
  p_from timestamptz,
  p_to timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_dining_order_count integer := 0;
  v_average_dining_seconds integer := 0;
BEGIN
  v_result := public.get_paperless_operations_report_pre_meal_start(
    p_store_id, p_from, p_to
  );

  WITH scoped_orders AS MATERIALIZED (
    SELECT DISTINCT ON (queue.order_id)
      queue.session_id,
      queue.order_id,
      order_row.status AS order_status
    FROM public.emergency_order_queue queue
    JOIN public.orders order_row
      ON order_row.id = queue.order_id
     AND order_row.restaurant_id = queue.restaurant_id
    WHERE queue.restaurant_id = p_store_id
      AND queue.created_at >= p_from
      AND queue.created_at < p_to
    ORDER BY queue.order_id, queue.created_at, queue.id
  ),
  first_service AS MATERIALIZED (
    SELECT scoped.order_id,
      min(event.created_at) AS first_floor_served_at
    FROM scoped_orders scoped
    JOIN public.emergency_fulfillment_events event
      ON event.session_id = scoped.session_id
     AND event.order_id = scoped.order_id
     AND event.restaurant_id = p_store_id
     AND event.stage = 'floor_served'
     AND event.delta > 0
    GROUP BY scoped.order_id
  ),
  payment_times AS MATERIALIZED (
    SELECT payment.order_id, max(payment.created_at) AS paid_at
    FROM public.payments payment
    JOIN scoped_orders scoped ON scoped.order_id = payment.order_id
    WHERE payment.restaurant_id = p_store_id
    GROUP BY payment.order_id
  ),
  dining_durations AS MATERIALIZED (
    SELECT EXTRACT(epoch FROM (
      payment.paid_at - service.first_floor_served_at
    )) AS dining_seconds
    FROM scoped_orders scoped
    JOIN first_service service ON service.order_id = scoped.order_id
    JOIN payment_times payment ON payment.order_id = scoped.order_id
    WHERE scoped.order_status = 'completed'
      AND payment.paid_at >= service.first_floor_served_at
  )
  SELECT count(*)::integer,
    COALESCE(round(avg(dining_seconds))::integer, 0)
  INTO v_dining_order_count, v_average_dining_seconds
  FROM dining_durations
  WHERE dining_seconds >= 0;

  RETURN v_result || jsonb_build_object(
    'dining_order_count', v_dining_order_count,
    'average_dining_seconds', v_average_dining_seconds
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_paperless_operations_report(
  uuid, timestamptz, timestamptz
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_paperless_operations_report(
  uuid, timestamptz, timestamptz
) TO authenticated;

COMMENT ON FUNCTION public.get_paperless_operations_report(
  uuid, timestamptz, timestamptz
) IS
  'Returns paperless operation metrics with per-menu timing and dining time from first menu service through final payment.';

DO $$
DECLARE
  v_snapshot_definition text;
  v_completed_definition text;
  v_enrichment_definition text;
  v_report_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_snapshot()'::regprocedure
  ) INTO v_snapshot_definition;
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_today_completed()'::regprocedure
  ) INTO v_completed_definition;
  SELECT pg_catalog.pg_get_functiondef(
    'public.emergency_add_order_batch_timings(jsonb)'::regprocedure
  ) INTO v_enrichment_definition;
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'
      ::regprocedure
  ) INTO v_report_definition;

  IF v_snapshot_definition NOT LIKE '%emergency_add_order_batch_timings%'
     OR v_completed_definition NOT LIKE '%emergency_add_order_batch_timings%'
     OR v_enrichment_definition NOT LIKE '%batch_received_at%'
     OR v_enrichment_definition NOT LIKE '%kitchen_first_done_at%'
     OR v_enrichment_definition NOT LIKE '%floor_last_served_at%' THEN
    RAISE EXCEPTION 'PAPERLESS_BATCH_TIMING_SNAPSHOT_VERIFICATION_FAILED';
  END IF;

  IF v_report_definition NOT LIKE '%first_floor_served_at%'
     OR v_report_definition NOT LIKE
       '%payment.paid_at - service.first_floor_served_at%' THEN
    RAISE EXCEPTION 'PAPERLESS_MEAL_START_REPORT_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'emergency_events_order_item_stage_created'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_BATCH_TIMING_INDEX_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated', 'public.get_emergency_station_snapshot()', 'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon', 'public.get_emergency_station_snapshot()', 'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_emergency_station_snapshot_pre_batch_timing()', 'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_BATCH_TIMING_PRIVILEGE_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
