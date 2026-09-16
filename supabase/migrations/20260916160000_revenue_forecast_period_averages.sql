BEGIN;

-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.get_revenue_forecast_operating_averages(
  p_store_id uuid,
  p_from timestamptz,
  p_to timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_base jsonb;
  v_first_serve_sample_count integer := 0;
  v_average_first_serve_seconds integer := 0;
  v_hourly jsonb := '[]'::jsonb;
BEGIN
  -- Reuse the established report for authorization, range validation, and
  -- dining-time measurements. This function only adds forecast-specific,
  -- completed-period aggregates and never substitutes fixed assumptions.
  v_base := public.get_paperless_operations_insights_report(
    p_store_id,
    p_from,
    p_to
  );

  WITH scoped_orders AS MATERIALIZED (
    SELECT DISTINCT ON (queue.order_id)
      queue.session_id,
      queue.order_id,
      queue.created_at AS received_at
    FROM public.emergency_order_queue queue
    JOIN public.orders order_row
      ON order_row.id = queue.order_id
     AND order_row.restaurant_id = queue.restaurant_id
    WHERE queue.restaurant_id = p_store_id
      AND queue.created_at >= p_from
      AND queue.created_at < p_to
      AND order_row.status <> 'cancelled'
    ORDER BY queue.order_id, queue.created_at, queue.id
  ),
  ledger_state AS MATERIALIZED (
    SELECT progress.order_id,
      bool_and(progress.floor_complete) AS floor_complete
    FROM (
      SELECT item.order_id,
        item.floor_served_quantity >= item.ordered_quantity
          AS floor_complete
      FROM public.emergency_fulfillment_items item
      JOIN scoped_orders scoped
        ON scoped.session_id = item.session_id
       AND scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id
        AND item.is_cancelled = false

      UNION ALL

      SELECT item.order_id,
        item.floor_served_quantity >= item.ordered_quantity
      FROM public.emergency_floor_direct_items item
      JOIN scoped_orders scoped
        ON scoped.session_id = item.session_id
       AND scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id
        AND item.is_cancelled = false

      UNION ALL

      SELECT item.order_id,
        item.floor_served_quantity >= item.ordered_quantity
      FROM public.emergency_combo_component_items item
      JOIN scoped_orders scoped
        ON scoped.session_id = item.session_id
       AND scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id
        AND item.is_cancelled = false
    ) progress
    GROUP BY progress.order_id
  ),
  first_service AS MATERIALIZED (
    SELECT scoped.order_id,
      scoped.received_at,
      min(event.created_at) AS first_floor_served_at
    FROM scoped_orders scoped
    JOIN ledger_state state
      ON state.order_id = scoped.order_id
     AND state.floor_complete
    JOIN public.emergency_fulfillment_events event
      ON event.session_id = scoped.session_id
     AND event.order_id = scoped.order_id
     AND event.restaurant_id = p_store_id
     AND event.stage = 'floor_served'
     AND event.delta > 0
    GROUP BY scoped.order_id, scoped.received_at
  ),
  valid_first_service AS MATERIALIZED (
    SELECT order_id, received_at, first_floor_served_at,
      EXTRACT(epoch FROM (first_floor_served_at - received_at))
        AS first_serve_seconds
    FROM first_service
    WHERE first_floor_served_at >= received_at
  ),
  hourly AS MATERIALIZED (
    SELECT date_trunc(
        'hour', scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ) AS bucket,
      count(*)::integer AS order_count,
      count(service.order_id)::integer AS completed_count
    FROM scoped_orders scoped
    LEFT JOIN valid_first_service service
      ON service.order_id = scoped.order_id
    GROUP BY bucket
  )
  SELECT
    (SELECT count(*)::integer FROM valid_first_service),
    COALESCE((
      SELECT round(avg(first_serve_seconds))::integer
      FROM valid_first_service
    ), 0),
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'hour', to_char(bucket, 'YYYY-MM-DD"T"HH24:00:00'),
        'order_count', order_count,
        'completed_count', completed_count
      ) ORDER BY bucket)
      FROM hourly
    ), '[]'::jsonb)
  INTO v_first_serve_sample_count,
    v_average_first_serve_seconds,
    v_hourly;

  RETURN v_base || jsonb_build_object(
    'first_serve_sample_count', v_first_serve_sample_count,
    'average_first_serve_seconds', v_average_first_serve_seconds,
    'first_serve_is_order_received_proxy', true,
    'forecast_hourly_orders', v_hourly
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_revenue_forecast_operating_averages(
  uuid, timestamptz, timestamptz
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_revenue_forecast_operating_averages(
  uuid, timestamptz, timestamptz
) TO authenticated;

COMMENT ON FUNCTION public.get_revenue_forecast_operating_averages(
  uuid, timestamptz, timestamptz
) IS
  'Returns selected-period, sample-weighted restaurant forecast inputs without fixed fallback assumptions.';

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_revenue_forecast_operating_averages(uuid,timestamp with time zone,timestamp with time zone)'
      ::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%get_paperless_operations_insights_report%'
     OR v_definition NOT LIKE '%average_first_serve_seconds%'
     OR v_definition NOT LIKE '%first_serve_sample_count%'
     OR v_definition NOT LIKE '%forecast_hourly_orders%'
     OR v_definition NOT LIKE '%order_row.status <> ''cancelled''%'
     OR v_definition LIKE '%250000%'
     OR v_definition LIKE '%1.15%' THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PERIOD_AVERAGES_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_revenue_forecast_operating_averages(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_revenue_forecast_operating_averages(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PERIOD_AVERAGES_PRIVILEGE_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
