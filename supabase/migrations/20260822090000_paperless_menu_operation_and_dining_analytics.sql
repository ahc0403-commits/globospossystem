BEGIN;

-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.get_paperless_operations_report(
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
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_from >= p_to
     OR p_to > p_from + interval '366 days' THEN
    RAISE EXCEPTION 'PAPERLESS_REPORT_RANGE_INVALID';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  WITH scoped_orders AS MATERIALIZED (
    SELECT DISTINCT ON (queue.order_id)
      queue.session_id,
      queue.id AS queue_id,
      queue.order_id,
      queue.created_at AS received_at,
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
  ledger_state AS MATERIALIZED (
    SELECT progress.order_id,
      bool_and(progress.kitchen_complete) AS kitchen_complete,
      bool_and(progress.tray_complete) AS tray_complete,
      bool_and(progress.floor_complete) AS floor_complete
    FROM (
      SELECT item.order_id,
        item.kitchen_done_quantity >= item.ordered_quantity
          AS kitchen_complete,
        item.tray_dispatched_quantity >= item.ordered_quantity
          AS tray_complete,
        item.floor_served_quantity >= item.ordered_quantity
          AS floor_complete
      FROM public.emergency_fulfillment_items item
      JOIN scoped_orders scoped
        ON scoped.session_id = item.session_id
       AND scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id
        AND item.is_cancelled = false

      UNION ALL

      SELECT item.order_id, true, true,
        item.floor_served_quantity >= item.ordered_quantity
      FROM public.emergency_floor_direct_items item
      JOIN scoped_orders scoped
        ON scoped.session_id = item.session_id
       AND scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id
        AND item.is_cancelled = false

      UNION ALL

      SELECT item.order_id,
        item.kitchen_done_quantity >= item.ordered_quantity,
        item.tray_dispatched_quantity >= item.ordered_quantity,
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
  event_times AS MATERIALIZED (
    SELECT event.order_id,
      CASE WHEN state.kitchen_complete THEN max(event.created_at) FILTER (
        WHERE event.stage = 'kitchen_done' AND event.delta > 0
      ) END AS kitchen_done_at,
      CASE WHEN state.tray_complete THEN max(event.created_at) FILTER (
        WHERE event.stage = 'tray_dispatched' AND event.delta > 0
      ) END AS tray_dispatched_at,
      CASE WHEN state.floor_complete THEN max(event.created_at) FILTER (
        WHERE event.stage = 'floor_served' AND event.delta > 0
      ) END AS floor_served_at
    FROM public.emergency_fulfillment_events event
    JOIN scoped_orders scoped
      ON scoped.session_id = event.session_id
     AND scoped.order_id = event.order_id
    JOIN ledger_state state ON state.order_id = event.order_id
    WHERE event.restaurant_id = p_store_id
    GROUP BY event.order_id, state.kitchen_complete,
      state.tray_complete, state.floor_complete
  ),
  payment_times AS MATERIALIZED (
    SELECT payment.order_id, max(payment.created_at) AS paid_at
    FROM public.payments payment
    JOIN scoped_orders scoped ON scoped.order_id = payment.order_id
    WHERE payment.restaurant_id = p_store_id
    GROUP BY payment.order_id
  ),
  order_durations AS MATERIALIZED (
    SELECT scoped.order_id,
      CASE WHEN times.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        COALESCE(times.kitchen_done_at, scoped.received_at)
          - scoped.received_at
      )) END AS kitchen_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        COALESCE(
          times.tray_dispatched_at,
          times.kitchen_done_at,
          scoped.received_at
        ) - COALESCE(times.kitchen_done_at, scoped.received_at)
      )) END AS tray_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        times.floor_served_at - COALESCE(
          times.tray_dispatched_at,
          times.kitchen_done_at,
          scoped.received_at
        )
      )) END AS floor_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        times.floor_served_at - scoped.received_at
      )) END AS operation_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL
          AND scoped.order_status = 'completed'
          AND payment.paid_at >= times.floor_served_at THEN EXTRACT(epoch FROM (
        payment.paid_at - times.floor_served_at
      )) END AS dining_seconds,
      times.floor_served_at
    FROM scoped_orders scoped
    LEFT JOIN event_times times ON times.order_id = scoped.order_id
    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
  ),
  station_metrics AS MATERIALIZED (
    SELECT * FROM (
      SELECT 'kitchen'::text AS station,
        count(kitchen_seconds)::integer AS sample_count,
        COALESCE(round(avg(kitchen_seconds))::integer, 0) AS average_seconds,
        COALESCE(round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY kitchen_seconds
        ))::integer, 0) AS p50_seconds,
        COALESCE(round(percentile_cont(0.9) WITHIN GROUP (
          ORDER BY kitchen_seconds
        ))::integer, 0) AS p90_seconds
      FROM order_durations WHERE kitchen_seconds >= 0

      UNION ALL

      SELECT 'tray', count(tray_seconds)::integer,
        COALESCE(round(avg(tray_seconds))::integer, 0),
        COALESCE(round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY tray_seconds
        ))::integer, 0),
        COALESCE(round(percentile_cont(0.9) WITHIN GROUP (
          ORDER BY tray_seconds
        ))::integer, 0)
      FROM order_durations WHERE tray_seconds >= 0

      UNION ALL

      SELECT 'floor', count(floor_seconds)::integer,
        COALESCE(round(avg(floor_seconds))::integer, 0),
        COALESCE(round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY floor_seconds
        ))::integer, 0),
        COALESCE(round(percentile_cont(0.9) WITHIN GROUP (
          ORDER BY floor_seconds
        ))::integer, 0)
      FROM order_durations WHERE floor_seconds >= 0
    ) metrics
  ),
  current_backlog AS MATERIALIZED (
    SELECT 'kitchen'::text AS station,
      COALESCE(sum(item.ordered_quantity - item.kitchen_done_quantity), 0)
        ::integer AS quantity
    FROM public.emergency_fulfillment_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    WHERE item.restaurant_id = p_store_id AND item.is_cancelled = false

    UNION ALL

    SELECT 'tray', COALESCE(sum(
      item.kitchen_done_quantity - item.tray_dispatched_quantity
    ), 0)::integer
    FROM public.emergency_fulfillment_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    WHERE item.restaurant_id = p_store_id AND item.is_cancelled = false

    UNION ALL

    SELECT 'floor', COALESCE(sum(progress.unserved), 0)::integer
    FROM (
      SELECT item.restaurant_id, item.session_id,
        item.tray_dispatched_quantity - item.floor_served_quantity AS unserved
      FROM public.emergency_fulfillment_items item
      WHERE item.is_cancelled = false
      UNION ALL
      SELECT item.restaurant_id, item.session_id,
        item.ordered_quantity - item.floor_served_quantity
      FROM public.emergency_floor_direct_items item
      WHERE item.is_cancelled = false
    ) progress
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = progress.session_id AND session.status = 'active'
    WHERE progress.restaurant_id = p_store_id
  ),
  standard_line_events AS MATERIALIZED (
    SELECT item.id AS line_id,
      max(event.created_at) FILTER (
        WHERE event.stage = 'kitchen_done' AND event.delta > 0
      ) AS kitchen_done_at,
      max(event.created_at) FILTER (
        WHERE event.stage = 'tray_dispatched' AND event.delta > 0
      ) AS tray_dispatched_at,
      max(event.created_at) FILTER (
        WHERE event.stage = 'floor_served' AND event.delta > 0
      ) AS floor_served_at
    FROM public.emergency_fulfillment_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events event
      ON event.session_id = item.session_id
     AND event.order_item_id = item.order_item_id
     AND event.floor_direct_item_id IS NULL
     AND event.combo_component_item_id IS NULL
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
    GROUP BY item.id
  ),
  combo_line_events AS MATERIALIZED (
    SELECT item.id AS line_id,
      max(event.created_at) FILTER (
        WHERE event.stage = 'kitchen_done' AND event.delta > 0
      ) AS kitchen_done_at,
      max(event.created_at) FILTER (
        WHERE event.stage = 'tray_dispatched' AND event.delta > 0
      ) AS tray_dispatched_at,
      max(event.created_at) FILTER (
        WHERE event.stage = 'floor_served' AND event.delta > 0
      ) AS floor_served_at
    FROM public.emergency_combo_component_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events event
      ON event.combo_component_item_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
    GROUP BY item.id
  ),
  direct_line_events AS MATERIALIZED (
    SELECT item.id AS line_id,
      max(event.created_at) FILTER (
        WHERE event.stage = 'floor_served' AND event.delta > 0
      ) AS floor_served_at
    FROM public.emergency_floor_direct_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events event
      ON event.floor_direct_item_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
    GROUP BY item.id
  ),
  menu_line_durations AS MATERIALIZED (
    SELECT
      COALESCE(order_item.menu_item_id::text,
        'standard:' || lower(COALESCE(NULLIF(order_item.label, ''),
          NULLIF(order_item.display_name, ''), 'menu'))) AS menu_key,
      COALESCE(NULLIF(order_item.label, ''),
        NULLIF(order_item.display_name, ''), NULLIF(menu.name_ko, ''),
        NULLIF(menu.name, ''), '메뉴') AS name_ko,
      COALESCE(NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Món') AS name_vi,
      COALESCE(NULLIF(menu.name_en, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Menu') AS name_en,
      CASE WHEN item.kitchen_done_quantity >= item.ordered_quantity
          AND events.kitchen_done_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.kitchen_done_at - order_item.created_at
      )) END AS kitchen_seconds,
      CASE WHEN item.tray_dispatched_quantity >= item.ordered_quantity
          AND events.tray_dispatched_at IS NOT NULL
          AND events.kitchen_done_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.tray_dispatched_at - events.kitchen_done_at
      )) END AS tray_seconds,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL
          AND events.tray_dispatched_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - events.tray_dispatched_at
      )) END AS floor_seconds,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END AS operation_seconds
    FROM public.emergency_fulfillment_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
    JOIN standard_line_events events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
      AND NOT EXISTS (
        SELECT 1
        FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )

    UNION ALL

    SELECT
      COALESCE(item.component_menu_item_id::text,
        'combo:' || lower(item.name_ko)) AS menu_key,
      item.name_ko, item.name_vi, item.name_en,
      CASE WHEN item.kitchen_done_quantity >= item.ordered_quantity
          AND events.kitchen_done_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.kitchen_done_at - order_item.created_at
      )) END,
      CASE WHEN item.tray_dispatched_quantity >= item.ordered_quantity
          AND events.tray_dispatched_at IS NOT NULL
          AND events.kitchen_done_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.tray_dispatched_at - events.kitchen_done_at
      )) END,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL
          AND events.tray_dispatched_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - events.tray_dispatched_at
      )) END,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END
    FROM public.emergency_combo_component_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    JOIN combo_line_events events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false

    UNION ALL

    SELECT
      COALESCE(item.component_menu_item_id::text,
        'direct:' || lower(item.name_ko)) AS menu_key,
      item.name_ko, item.name_vi, item.name_en,
      NULL::numeric AS kitchen_seconds,
      NULL::numeric AS tray_seconds,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END AS floor_seconds,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END AS operation_seconds
    FROM public.emergency_floor_direct_items item
    JOIN scoped_orders scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    JOIN direct_line_events events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
  ),
  menu_metrics AS MATERIALIZED (
    SELECT menu_key,
      max(name_ko) AS name_ko,
      max(name_vi) AS name_vi,
      max(name_en) AS name_en,
      count(operation_seconds)::integer AS sample_count,
      CASE WHEN count(kitchen_seconds) > 0
        THEN round(avg(kitchen_seconds))::integer END
        AS kitchen_average_seconds,
      CASE WHEN count(tray_seconds) > 0
        THEN round(avg(tray_seconds))::integer END
        AS tray_average_seconds,
      CASE WHEN count(floor_seconds) > 0
        THEN round(avg(floor_seconds))::integer END
        AS floor_average_seconds,
      round(avg(operation_seconds))::integer AS operation_average_seconds
    FROM menu_line_durations
    WHERE operation_seconds >= 0
      AND (kitchen_seconds IS NULL OR kitchen_seconds >= 0)
      AND (tray_seconds IS NULL OR tray_seconds >= 0)
      AND (floor_seconds IS NULL OR floor_seconds >= 0)
    GROUP BY menu_key
  ),
  hourly AS MATERIALIZED (
    SELECT date_trunc(
        'hour', scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ) AS bucket,
      count(*)::integer AS order_count,
      count(*) FILTER (WHERE duration.floor_served_at IS NOT NULL)::integer
        AS completed_count
    FROM scoped_orders scoped
    LEFT JOIN order_durations duration ON duration.order_id = scoped.order_id
    GROUP BY bucket
  )
  SELECT jsonb_build_object(
    'order_count', (SELECT count(*) FROM scoped_orders),
    'completed_order_count', (
      SELECT count(*) FROM order_durations WHERE floor_served_at IS NOT NULL
    ),
    'dining_order_count', (
      SELECT count(dining_seconds) FROM order_durations
      WHERE dining_seconds >= 0
    ),
    'average_total_seconds', COALESCE((
      SELECT round(avg(operation_seconds))::integer
      FROM order_durations WHERE operation_seconds >= 0
    ), 0),
    'average_operation_seconds', COALESCE((
      SELECT round(avg(operation_seconds))::integer
      FROM order_durations WHERE operation_seconds >= 0
    ), 0),
    'average_dining_seconds', COALESCE((
      SELECT round(avg(dining_seconds))::integer
      FROM order_durations WHERE dining_seconds >= 0
    ), 0),
    'p90_total_seconds', COALESCE((
      SELECT round(percentile_cont(0.9) WITHIN GROUP (
        ORDER BY operation_seconds
      ))::integer FROM order_durations WHERE operation_seconds >= 0
    ), 0),
    'bottleneck_station', COALESCE((
      SELECT station FROM station_metrics
      WHERE sample_count > 0 ORDER BY p90_seconds DESC, station LIMIT 1
    ), 'none'),
    'stations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'station', metric.station,
        'sample_count', metric.sample_count,
        'average_seconds', metric.average_seconds,
        'p50_seconds', metric.p50_seconds,
        'p90_seconds', metric.p90_seconds,
        'backlog_quantity', COALESCE(backlog.quantity, 0)
      ) ORDER BY CASE metric.station
        WHEN 'kitchen' THEN 1 WHEN 'tray' THEN 2 ELSE 3 END)
      FROM station_metrics metric
      LEFT JOIN current_backlog backlog ON backlog.station = metric.station
    ), '[]'::jsonb),
    'menu_operation_times', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'menu_key', metric.menu_key,
        'name', metric.name_ko,
        'name_ko', metric.name_ko,
        'name_vi', metric.name_vi,
        'name_en', metric.name_en,
        'sample_count', metric.sample_count,
        'kitchen_average_seconds', metric.kitchen_average_seconds,
        'tray_average_seconds', metric.tray_average_seconds,
        'floor_average_seconds', metric.floor_average_seconds,
        'operation_average_seconds', metric.operation_average_seconds
      ) ORDER BY metric.operation_average_seconds DESC, metric.name_ko)
      FROM menu_metrics metric
    ), '[]'::jsonb),
    'menu_kitchen_times', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', ranked.name,
        'sample_count', ranked.sample_count,
        'average_seconds', ranked.average_seconds,
        'p90_seconds', ranked.p90_seconds
      ) ORDER BY ranked.p90_seconds DESC, ranked.name)
      FROM (
        SELECT max(name_ko) AS name,
          count(kitchen_seconds)::integer AS sample_count,
          round(avg(kitchen_seconds))::integer AS average_seconds,
          round(percentile_cont(0.9) WITHIN GROUP (
            ORDER BY kitchen_seconds
          ))::integer AS p90_seconds
        FROM menu_line_durations
        WHERE kitchen_seconds >= 0
        GROUP BY menu_key
        ORDER BY p90_seconds DESC
        LIMIT 10
      ) ranked
    ), '[]'::jsonb),
    'hourly_orders', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'hour', to_char(bucket, 'YYYY-MM-DD"T"HH24:00:00'),
        'order_count', order_count,
        'completed_count', completed_count
      ) ORDER BY bucket) FROM hourly
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
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
  'Returns additive kitchen, tray, and floor operation times per menu plus order-level dining time from full delivery to final payment.';

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'
      ::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%average_dining_seconds%'
     OR v_definition NOT LIKE '%menu_operation_times%'
     OR v_definition NOT LIKE '%payment.paid_at - times.floor_served_at%'
     OR v_definition NOT LIKE '%order_item.created_at%' THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_OPERATION_ANALYTICS_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_OPERATION_ANALYTICS_GRANT_FAILED';
  END IF;
END;
$$;

COMMIT;
