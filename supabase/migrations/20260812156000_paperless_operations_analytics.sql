BEGIN;

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
    SELECT queue.id AS queue_id, queue.order_id, queue.created_at
    FROM public.emergency_order_queue queue
    WHERE queue.restaurant_id = p_store_id
      AND queue.created_at >= p_from AND queue.created_at < p_to
  ),
  ledger_state AS MATERIALIZED (
    SELECT progress.order_id,
      bool_and(progress.kitchen_complete) AS kitchen_complete,
      bool_and(progress.tray_complete) AS tray_complete,
      bool_and(progress.floor_complete) AS floor_complete
    FROM (
      SELECT item.order_id,
        item.kitchen_done_quantity >= item.ordered_quantity AS kitchen_complete,
        item.tray_dispatched_quantity >= item.ordered_quantity AS tray_complete,
        item.floor_served_quantity >= item.ordered_quantity AS floor_complete
      FROM public.emergency_fulfillment_items item
      JOIN scoped_orders scoped ON scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id AND item.is_cancelled = false
      UNION ALL
      SELECT item.order_id, true, true,
        item.floor_served_quantity >= item.ordered_quantity
      FROM public.emergency_floor_direct_items item
      JOIN scoped_orders scoped ON scoped.order_id = item.order_id
      WHERE item.restaurant_id = p_store_id AND item.is_cancelled = false
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
      max(event.created_at) FILTER (
        WHERE event.stage = 'floor_direct_ready' AND event.delta > 0
      ) AS floor_direct_ready_at,
      CASE WHEN state.floor_complete THEN max(event.created_at) FILTER (
        WHERE event.stage = 'floor_served' AND event.delta > 0
      ) END AS floor_served_at
    FROM public.emergency_fulfillment_events event
    JOIN scoped_orders scoped ON scoped.order_id = event.order_id
    JOIN ledger_state state ON state.order_id = event.order_id
    WHERE event.restaurant_id = p_store_id
    GROUP BY event.order_id, state.kitchen_complete,
      state.tray_complete, state.floor_complete
  ),
  order_durations AS MATERIALIZED (
    SELECT scoped.order_id, scoped.created_at,
      CASE WHEN times.kitchen_done_at IS NOT NULL THEN
        EXTRACT(epoch FROM (times.kitchen_done_at - scoped.created_at))
      END AS kitchen_seconds,
      CASE WHEN times.tray_dispatched_at IS NOT NULL
          AND times.kitchen_done_at IS NOT NULL THEN
        EXTRACT(epoch FROM (times.tray_dispatched_at - times.kitchen_done_at))
      END AS tray_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL THEN
        EXTRACT(epoch FROM (
          times.floor_served_at - COALESCE(
            times.tray_dispatched_at,
            times.floor_direct_ready_at,
            scoped.created_at
          )
        ))
      END AS floor_seconds,
      CASE WHEN times.floor_served_at IS NOT NULL THEN
        EXTRACT(epoch FROM (times.floor_served_at - scoped.created_at))
      END AS total_seconds,
      times.floor_served_at
    FROM scoped_orders scoped
    LEFT JOIN event_times times ON times.order_id = scoped.order_id
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
      COALESCE(sum(item.ordered_quantity - item.kitchen_done_quantity), 0)::integer
        AS quantity
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
  menu_samples AS MATERIALIZED (
    SELECT item.order_item_id,
      COALESCE(NULLIF(order_item.label, ''), NULLIF(order_item.display_name, ''),
        NULLIF(menu.name_ko, ''), NULLIF(menu.name, ''), '메뉴') AS name,
      EXTRACT(epoch FROM (
        max(event.created_at) FILTER (
          WHERE event.stage = 'kitchen_done' AND event.delta > 0
        ) - min(scoped.created_at)
      )) AS kitchen_seconds
    FROM public.emergency_fulfillment_items item
    JOIN scoped_orders scoped ON scoped.order_id = item.order_id
    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
    LEFT JOIN public.emergency_fulfillment_events event
      ON event.order_item_id = item.order_item_id
      AND event.session_id = item.session_id
    WHERE item.restaurant_id = p_store_id AND item.is_cancelled = false
    GROUP BY item.order_item_id, order_item.label, order_item.display_name,
      menu.name_ko, menu.name
  ),
  hourly AS MATERIALIZED (
    SELECT date_trunc(
        'hour', scoped.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
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
    'average_total_seconds', COALESCE((
      SELECT round(avg(total_seconds))::integer
      FROM order_durations WHERE total_seconds >= 0
    ), 0),
    'p90_total_seconds', COALESCE((
      SELECT round(percentile_cont(0.9) WITHIN GROUP (
        ORDER BY total_seconds
      ))::integer FROM order_durations WHERE total_seconds >= 0
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
    'menu_kitchen_times', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', ranked.name,
        'sample_count', ranked.sample_count,
        'average_seconds', ranked.average_seconds,
        'p90_seconds', ranked.p90_seconds
      ) ORDER BY ranked.p90_seconds DESC, ranked.name)
      FROM (
        SELECT name, count(kitchen_seconds)::integer AS sample_count,
          round(avg(kitchen_seconds))::integer AS average_seconds,
          round(percentile_cont(0.9) WITHIN GROUP (
            ORDER BY kitchen_seconds
          ))::integer AS p90_seconds
        FROM menu_samples WHERE kitchen_seconds >= 0
        GROUP BY name ORDER BY p90_seconds DESC LIMIT 10
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

COMMIT;
