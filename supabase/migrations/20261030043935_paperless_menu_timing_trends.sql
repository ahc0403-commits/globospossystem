BEGIN;

-- production-gate: self-verifying
-- Freeze the effective report's corrected sample computation into this read RPC.
-- Reuse its completion, combo, cancellation and historical-menu identity rules;
-- do not execute the report once per menu or bucket. Fail closed if it changes.
DO $migration$
DECLARE
  source text := pg_get_functiondef(
    'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure
  );
  prefix text;
  lines text;
  source_start integer;
  lines_start integer;
  source_end integer;
BEGIN
  source_start := strpos(source, 'WITH scoped_orders AS MATERIALIZED (');
  lines_start := strpos(source, 'menu_line_durations AS MATERIALIZED (');
  source_end := strpos(source, E',\n  menu_metrics AS MATERIALIZED (');
  IF source_start = 0 OR lines_start <= source_start OR source_end <= lines_start THEN
    RAISE EXCEPTION 'PAPERLESS_TREND_SOURCE_CHANGED';
  END IF;
  prefix := substring(source FROM source_start FOR lines_start - source_start);
  lines := substring(source FROM lines_start FOR source_end - lines_start);
  IF (length(prefix) - length(replace(prefix, 'queue.created_at >= p_from', '')))
       / length('queue.created_at >= p_from') <> 1
     OR (length(lines) - length(replace(lines, E'SELECT\n      COALESCE(', '')))
       / length(E'SELECT\n      COALESCE(') <> 3
     OR lines NOT LIKE '%was_corrected%' THEN
    RAISE EXCEPTION 'PAPERLESS_TREND_SAMPLE_ANCHOR_CHANGED';
  END IF;
  prefix := replace(prefix, 'queue.created_at >= p_from',
    'queue.created_at >= p_from - (p_to - p_from)');
  -- A queue can contain the same order in both periods. Keep its first row
  -- independently in each cohort, matching the two canonical report calls.
  prefix := replace(prefix, 'DISTINCT ON (queue.order_id)',
    'DISTINCT ON (queue.order_id, (queue.created_at >= p_from))');
  prefix := replace(prefix, 'ORDER BY queue.order_id, queue.created_at, queue.id',
    'ORDER BY queue.order_id, (queue.created_at >= p_from), queue.created_at, queue.id');
  lines := replace(lines, E'SELECT\n      COALESCE(',
    E'SELECT\n      scoped.received_at,\n      COALESCE(');

  EXECUTE replace($definition$
CREATE OR REPLACE FUNCTION public.get_paperless_menu_timing_trends(
  p_store_id uuid, p_from timestamptz, p_to timestamptz
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $body$
DECLARE
  v_unit text;
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_from >= p_to
     OR p_to > p_from + interval '366 days' THEN
    RAISE EXCEPTION 'PAPERLESS_REPORT_RANGE_INVALID';
  END IF;
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_TREND_AUTH_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  v_unit := CASE WHEN p_to - p_from <= interval '14 days' THEN 'day'
    WHEN p_to - p_from <= interval '84 days' THEN 'week' ELSE 'month' END;

  __TIMING_SOURCE__,
  valid_samples AS MATERIALIZED (
    SELECT * FROM menu_line_durations WHERE operation_seconds >= 0
  ),
  buckets AS MATERIALIZED (
    SELECT (row_number() OVER (ORDER BY boundary) - 1)::integer AS bucket_index,
      boundary,
      greatest(boundary AT TIME ZONE 'Asia/Ho_Chi_Minh', p_from) AS from_at,
      least((boundary + ('1 ' || v_unit)::interval)
        AT TIME ZONE 'Asia/Ho_Chi_Minh', p_to) AS to_at
    FROM generate_series(
      date_trunc(v_unit, p_from AT TIME ZONE 'Asia/Ho_Chi_Minh'),
      (p_to - interval '1 microsecond') AT TIME ZONE 'Asia/Ho_Chi_Minh',
      ('1 ' || v_unit)::interval
    ) AS boundary
  ),
  bucket_metrics AS MATERIALIZED (
    SELECT sample.menu_key, bucket.bucket_index,
      count(*)::integer AS sample_count,
      round(avg(sample.operation_seconds))::integer AS average_seconds
    FROM valid_samples sample
    JOIN buckets bucket ON bucket.boundary = date_trunc(
      v_unit, sample.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
    )
    WHERE sample.received_at >= p_from AND sample.received_at < p_to
    GROUP BY sample.menu_key, bucket.bucket_index
  ),
  menu_totals AS MATERIALIZED (
    SELECT sample.menu_key,
      COALESCE(max(sample.name_ko) FILTER (WHERE sample.was_corrected),
        NULLIF(max(menu.name_ko), ''), max(sample.name_ko)) AS name_ko,
      COALESCE(max(sample.name_vi) FILTER (WHERE sample.was_corrected),
        NULLIF(max(menu.name_vi), ''), max(sample.name_vi)) AS name_vi,
      COALESCE(max(sample.name_en) FILTER (WHERE sample.was_corrected),
        NULLIF(max(menu.name_en), ''), max(sample.name_en)) AS name_en,
      count(*) FILTER (WHERE sample.received_at < p_from)::integer
        AS baseline_sample_count,
      round(avg(sample.operation_seconds) FILTER (WHERE sample.received_at < p_from))::integer
        AS baseline_average_seconds,
      count(*) FILTER (WHERE sample.received_at >= p_from)::integer
        AS current_sample_count,
      round(avg(sample.operation_seconds) FILTER (WHERE sample.received_at >= p_from))::integer
        AS current_average_seconds
    FROM valid_samples sample
    LEFT JOIN public.menu_items menu ON menu.id::text = sample.menu_key
      AND menu.restaurant_id = p_store_id
    GROUP BY sample.menu_key
  ),
  menu_points AS (
    SELECT menu_key, jsonb_agg(jsonb_build_object(
      'bucket_index', bucket_index, 'sample_count', sample_count,
      'average_seconds', average_seconds
    ) ORDER BY bucket_index) AS points
    FROM bucket_metrics GROUP BY menu_key
  )
  SELECT jsonb_build_object(
    'baseline_from', ((p_from - (p_to - p_from)) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    'baseline_to', ((p_from - interval '1 microsecond') AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    'bucket_unit', v_unit,
    'buckets', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'index', bucket_index,
      'from_date', (from_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
      'to_date', ((to_at - interval '1 microsecond') AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) ORDER BY bucket_index), '[]'::jsonb) FROM buckets),
    'menus', (SELECT COALESCE(jsonb_agg(
      to_jsonb(total) || jsonb_build_object('points', COALESCE(point.points, '[]'::jsonb))
      ORDER BY total.menu_key
    ), '[]'::jsonb)
      FROM menu_totals total LEFT JOIN menu_points point USING (menu_key))
  ) INTO v_result;
  RETURN v_result;
END;
$body$;
$definition$, '__TIMING_SOURCE__', prefix || lines);
END;
$migration$;

REVOKE ALL ON FUNCTION public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz)
  TO authenticated;

COMMENT ON FUNCTION public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz) IS
  'Admin-only, batched menu service-time trends with a fixed preceding equal-length baseline. Daily up to 14 days, weekly up to 84 days, monthly thereafter; Vietnam business dates, completed line samples, unrounded sample-weighted means.';

DO $verify$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz)'::regprocedure
  ) INTO definition;
  IF definition NOT LIKE '%require_admin_actor_for_restaurant(p_store_id)%'
    OR definition NOT LIKE '%auth.uid() IS NULL%'
    OR definition NOT LIKE '%scoped.received_at%'
    OR definition NOT LIKE '%baseline_average_seconds%'
    OR definition NOT LIKE '%Asia/Ho_Chi_Minh%'
    OR has_function_privilege('anon',
      'public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated',
      'public.get_paperless_menu_timing_trends(uuid,timestamptz,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PAPERLESS_TREND_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
