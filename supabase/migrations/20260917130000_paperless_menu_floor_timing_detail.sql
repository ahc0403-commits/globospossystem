BEGIN;

-- production-gate: self-verifying
-- Preserve the physical table floor separately from the two-station KDS routing
-- bucket. Historical rows are best-effort backfilled from the current table
-- record and explicitly marked as inferred.

ALTER TABLE public.emergency_order_queue
  ADD COLUMN IF NOT EXISTS physical_floor_label text,
  ADD COLUMN IF NOT EXISTS physical_floor_inferred boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.emergency_order_queue.physical_floor_label IS
  'Physical table floor captured when the paperless queue row is inserted; distinct from the KDS routing floor_label.';
COMMENT ON COLUMN public.emergency_order_queue.physical_floor_inferred IS
  'True when physical_floor_label was reconstructed or fell back to the routing floor instead of being captured at insert time.';

UPDATE public.emergency_order_queue AS queue
SET physical_floor_label = COALESCE(
      NULLIF(upper(btrim(table_row.floor_label)), ''),
      NULLIF(upper(btrim(queue.floor_label)), '')
    ),
    physical_floor_inferred = true
FROM public.orders AS order_row
LEFT JOIN public.tables AS table_row
  ON table_row.id = order_row.table_id
 AND table_row.restaurant_id = order_row.restaurant_id
WHERE order_row.id = queue.order_id
  AND order_row.restaurant_id = queue.restaurant_id
  AND NULLIF(btrim(COALESCE(queue.physical_floor_label, '')), '') IS NULL;

CREATE OR REPLACE FUNCTION public.capture_emergency_queue_physical_floor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_physical_floor text;
BEGIN
  SELECT NULLIF(upper(btrim(table_row.floor_label)), '')
  INTO v_physical_floor
  FROM public.orders AS order_row
  LEFT JOIN public.tables AS table_row
    ON table_row.id = order_row.table_id
   AND table_row.restaurant_id = order_row.restaurant_id
  WHERE order_row.id = NEW.order_id
    AND order_row.restaurant_id = NEW.restaurant_id;

  IF v_physical_floor IS NOT NULL THEN
    NEW.physical_floor_label := v_physical_floor;
    NEW.physical_floor_inferred := false;
  ELSE
    NEW.physical_floor_label := COALESCE(
      NULLIF(upper(btrim(NEW.physical_floor_label)), ''),
      NULLIF(upper(btrim(NEW.floor_label)), '')
    );
    NEW.physical_floor_inferred := true;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.capture_emergency_queue_physical_floor()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS capture_emergency_queue_physical_floor_trigger
  ON public.emergency_order_queue;
CREATE TRIGGER capture_emergency_queue_physical_floor_trigger
BEFORE INSERT ON public.emergency_order_queue
FOR EACH ROW EXECUTE FUNCTION public.capture_emergency_queue_physical_floor();

CREATE INDEX IF NOT EXISTS emergency_queue_store_created_order
  ON public.emergency_order_queue (restaurant_id, created_at, order_id);

CREATE OR REPLACE FUNCTION public.get_paperless_menu_timing_detail(
  p_store_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_menu_key text,
  p_floor_label text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_after_floor_seconds numeric DEFAULT NULL,
  p_after_sample_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_limit integer;
  v_menu_key text := NULLIF(btrim(COALESCE(p_menu_key, '')), '');
  v_floor_label text := NULLIF(upper(btrim(COALESCE(p_floor_label, ''))), '');
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_from >= p_to
     OR p_to > p_from + interval '366 days' THEN
    RAISE EXCEPTION 'PAPERLESS_REPORT_RANGE_INVALID';
  END IF;
  IF v_menu_key IS NULL OR length(v_menu_key) > 240 THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_DETAIL_KEY_INVALID';
  END IF;
  IF v_floor_label IS NOT NULL AND length(v_floor_label) > 32 THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_DETAIL_FLOOR_INVALID';
  END IF;
  IF (p_after_floor_seconds IS NULL) <> (p_after_sample_key IS NULL)
     OR p_after_floor_seconds < 0
     OR length(COALESCE(p_after_sample_key, '')) > 160 THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_DETAIL_CURSOR_INVALID';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  WITH scoped_orders AS MATERIALIZED (
    SELECT DISTINCT ON (queue.order_id)
      queue.session_id,
      queue.id AS queue_id,
      queue.order_id,
      queue.queue_no,
      queue.table_number,
      COALESCE(
        NULLIF(upper(btrim(queue.physical_floor_label)), ''),
        NULLIF(upper(btrim(table_row.floor_label)), ''),
        NULLIF(upper(btrim(queue.floor_label)), ''),
        'UNKNOWN'
      ) AS physical_floor_label,
      upper(queue.floor_label) AS routing_floor_label,
      CASE
        WHEN NULLIF(btrim(queue.physical_floor_label), '') IS NULL THEN true
        ELSE queue.physical_floor_inferred
      END AS physical_floor_inferred
    FROM public.emergency_order_queue AS queue
    JOIN public.orders AS order_row
      ON order_row.id = queue.order_id
     AND order_row.restaurant_id = queue.restaurant_id
    LEFT JOIN public.tables AS table_row
      ON table_row.id = order_row.table_id
     AND table_row.restaurant_id = order_row.restaurant_id
    WHERE queue.restaurant_id = p_store_id
      AND queue.created_at >= p_from
      AND queue.created_at < p_to
    ORDER BY queue.order_id, queue.created_at, queue.id
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
    FROM public.emergency_fulfillment_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events AS event
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
    FROM public.emergency_combo_component_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events AS event
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
    FROM public.emergency_floor_direct_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    LEFT JOIN public.emergency_fulfillment_events AS event
      ON event.floor_direct_item_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
    GROUP BY item.id
  ),
  menu_line_samples AS MATERIALIZED (
    SELECT
      'standard:' || item.id::text AS sample_key,
      COALESCE(
        order_item.menu_item_id::text,
        'standard:' || lower(COALESCE(
          NULLIF(order_item.label, ''),
          NULLIF(order_item.display_name, ''),
          'menu'
        ))
      ) AS menu_key,
      'kitchen_tray_floor'::text AS route_type,
      scoped.order_id,
      order_item.id AS order_item_id,
      scoped.queue_no,
      scoped.table_number,
      scoped.physical_floor_label,
      scoped.routing_floor_label,
      scoped.physical_floor_inferred,
      item.ordered_quantity,
      order_item.created_at AS received_at,
      events.kitchen_done_at,
      events.tray_dispatched_at,
      events.floor_served_at,
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
    FROM public.emergency_fulfillment_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN standard_line_events AS events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
      AND NOT EXISTS (
        SELECT 1
        FROM public.emergency_combo_component_items AS component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )

    UNION ALL

    SELECT
      'combo:' || item.id::text,
      COALESCE(
        item.component_menu_item_id::text,
        'combo:' || lower(item.name_ko)
      ),
      'combo_component',
      scoped.order_id,
      order_item.id,
      scoped.queue_no,
      scoped.table_number,
      scoped.physical_floor_label,
      scoped.routing_floor_label,
      scoped.physical_floor_inferred,
      item.ordered_quantity,
      order_item.created_at,
      events.kitchen_done_at,
      events.tray_dispatched_at,
      events.floor_served_at,
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
    FROM public.emergency_combo_component_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN combo_line_events AS events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false

    UNION ALL

    SELECT
      'direct:' || item.id::text,
      COALESCE(
        item.component_menu_item_id::text,
        'direct:' || lower(item.name_ko)
      ),
      'floor_direct',
      scoped.order_id,
      order_item.id,
      scoped.queue_no,
      scoped.table_number,
      scoped.physical_floor_label,
      scoped.routing_floor_label,
      scoped.physical_floor_inferred,
      item.ordered_quantity,
      order_item.created_at,
      NULL::timestamptz,
      NULL::timestamptz,
      events.floor_served_at,
      NULL::numeric,
      NULL::numeric,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END,
      CASE WHEN item.floor_served_quantity >= item.ordered_quantity
          AND events.floor_served_at IS NOT NULL THEN EXTRACT(epoch FROM (
        events.floor_served_at - order_item.created_at
      )) END
    FROM public.emergency_floor_direct_items AS item
    JOIN scoped_orders AS scoped
      ON scoped.session_id = item.session_id
     AND scoped.order_id = item.order_id
    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN direct_line_events AS events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id
      AND item.is_cancelled = false
  ),
  matching_samples AS MATERIALIZED (
    SELECT *
    FROM menu_line_samples
    WHERE menu_key = v_menu_key
      AND operation_seconds >= 0
      AND (kitchen_seconds IS NULL OR kitchen_seconds >= 0)
      AND (tray_seconds IS NULL OR tray_seconds >= 0)
      AND (floor_seconds IS NULL OR floor_seconds >= 0)
  ),
  floor_samples AS MATERIALIZED (
    SELECT * FROM matching_samples WHERE floor_seconds IS NOT NULL
  ),
  floor_summaries AS MATERIALIZED (
    SELECT physical_floor_label,
      count(*)::integer AS sample_count,
      count(*) FILTER (WHERE physical_floor_inferred)::integer
        AS inferred_sample_count,
      round(avg(floor_seconds))::integer AS average_floor_seconds,
      round(percentile_cont(0.9) WITHIN GROUP (
        ORDER BY floor_seconds
      ))::integer AS p90_floor_seconds,
      round(max(floor_seconds))::integer AS max_floor_seconds
    FROM floor_samples
    GROUP BY physical_floor_label
  ),
  filtered_samples AS MATERIALIZED (
    SELECT *
    FROM floor_samples
    WHERE (v_floor_label IS NULL OR physical_floor_label = v_floor_label)
      AND (
        p_after_floor_seconds IS NULL
        OR floor_seconds < p_after_floor_seconds
        OR (
          floor_seconds = p_after_floor_seconds
          AND sample_key < p_after_sample_key
        )
      )
  ),
  paged_samples AS MATERIALIZED (
    SELECT *
    FROM filtered_samples
    ORDER BY floor_seconds DESC, sample_key DESC
    LIMIT v_limit + 1
  ),
  visible_samples AS MATERIALIZED (
    SELECT *
    FROM paged_samples
    ORDER BY floor_seconds DESC, sample_key DESC
    LIMIT v_limit
  )
  SELECT jsonb_build_object(
    'overall_summary', jsonb_build_object(
      'operation_sample_count', (SELECT count(*) FROM matching_samples),
      'floor_sample_count', (SELECT count(*) FROM floor_samples),
      'kitchen_average_seconds', (
        SELECT round(avg(kitchen_seconds))::integer
        FROM matching_samples WHERE kitchen_seconds IS NOT NULL
      ),
      'tray_average_seconds', (
        SELECT round(avg(tray_seconds))::integer
        FROM matching_samples WHERE tray_seconds IS NOT NULL
      ),
      'floor_average_seconds', (
        SELECT round(avg(floor_seconds))::integer FROM floor_samples
      ),
      'operation_average_seconds', (
        SELECT round(avg(operation_seconds))::integer FROM matching_samples
      )
    ),
    'floor_summaries', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'physical_floor_label', summary.physical_floor_label,
        'sample_count', summary.sample_count,
        'inferred_sample_count', summary.inferred_sample_count,
        'average_floor_seconds', summary.average_floor_seconds,
        'p90_floor_seconds', summary.p90_floor_seconds,
        'max_floor_seconds', summary.max_floor_seconds
      ) ORDER BY summary.average_floor_seconds DESC,
        summary.physical_floor_label)
      FROM floor_summaries AS summary
    ), '[]'::jsonb),
    'samples', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'sample_key', sample.sample_key,
        'order_id', sample.order_id,
        'order_item_id', sample.order_item_id,
        'queue_no', sample.queue_no,
        'table_number', sample.table_number,
        'physical_floor_label', sample.physical_floor_label,
        'routing_floor_label', sample.routing_floor_label,
        'physical_floor_inferred', sample.physical_floor_inferred,
        'route_type', sample.route_type,
        'ordered_quantity', sample.ordered_quantity,
        'received_at', sample.received_at,
        'kitchen_done_at', sample.kitchen_done_at,
        'tray_dispatched_at', sample.tray_dispatched_at,
        'floor_served_at', sample.floor_served_at,
        'kitchen_seconds', round(sample.kitchen_seconds)::integer,
        'tray_seconds', round(sample.tray_seconds)::integer,
        'floor_seconds', round(sample.floor_seconds)::integer,
        'operation_seconds', round(sample.operation_seconds)::integer
      ) ORDER BY sample.floor_seconds DESC, sample.sample_key DESC)
      FROM visible_samples AS sample
    ), '[]'::jsonb),
    'total_count', (SELECT count(*) FROM floor_samples
      WHERE v_floor_label IS NULL OR physical_floor_label = v_floor_label),
    'has_more', (SELECT count(*) > v_limit FROM paged_samples),
    'next_cursor', CASE
      WHEN (SELECT count(*) > v_limit FROM paged_samples) THEN (
        SELECT jsonb_build_object(
          'floor_seconds', sample.floor_seconds,
          'sample_key', sample.sample_key
        )
        FROM visible_samples AS sample
        ORDER BY sample.floor_seconds ASC, sample.sample_key ASC
        LIMIT 1
      )
      ELSE NULL
    END
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_paperless_menu_timing_detail(
  uuid, timestamptz, timestamptz, text, text, integer, numeric, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_paperless_menu_timing_detail(
  uuid, timestamptz, timestamptz, text, text, integer, numeric, text
) TO authenticated;

COMMENT ON FUNCTION public.get_paperless_menu_timing_detail(
  uuid, timestamptz, timestamptz, text, text, integer, numeric, text
) IS
  'Returns lazy-loaded physical-floor summaries and slowest-first menu service samples using the established paperless timing definitions.';

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_paperless_menu_timing_detail(uuid,timestamp with time zone,timestamp with time zone,text,text,integer,numeric,text)'
      ::regprocedure
  ) INTO v_definition;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_order_queue'
      AND column_name = 'physical_floor_label'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger
    WHERE tgname = 'capture_emergency_queue_physical_floor_trigger'
      AND tgrelid = 'public.emergency_order_queue'::regclass
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'emergency_queue_store_created_order'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_FLOOR_FOUNDATION_VERIFICATION_FAILED';
  END IF;

  IF v_definition NOT LIKE '%require_admin_actor_for_restaurant%'
     OR v_definition NOT LIKE '%physical_floor_label%'
     OR v_definition NOT LIKE '%percentile_cont(0.9)%'
     OR v_definition NOT LIKE '%p_after_floor_seconds%'
     OR v_definition NOT LIKE '%events.floor_served_at - events.tray_dispatched_at%'
     OR v_definition NOT LIKE '%events.floor_served_at - order_item.created_at%' THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_DETAIL_DEFINITION_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_paperless_menu_timing_detail(uuid,timestamp with time zone,timestamp with time zone,text,text,integer,numeric,text)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_paperless_menu_timing_detail(uuid,timestamp with time zone,timestamp with time zone,text,text,integer,numeric,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_DETAIL_PRIVILEGE_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
