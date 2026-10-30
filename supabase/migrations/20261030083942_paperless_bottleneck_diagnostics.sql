BEGIN;
-- production-gate: self-verifying
-- Freeze the effective, corrected completion sample computation, once. No
-- business rows change and no report is executed once per menu/hour/stage.
DO $migration$
DECLARE
 source text := pg_get_functiondef(
  'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure);
 prefix text; lines text; parts text[]; piece text; i integer;
 source_start integer; lines_start integer; source_end integer;
BEGIN
 source_start := strpos(source,'WITH scoped_orders AS MATERIALIZED (');
 lines_start := strpos(source,'menu_line_durations AS MATERIALIZED (');
 source_end := strpos(source,E',\n  menu_metrics AS MATERIALIZED (');
 IF source_start=0 OR lines_start<=source_start OR source_end<=lines_start THEN
  RAISE EXCEPTION 'PAPERLESS_BOTTLENECK_SOURCE_CHANGED';
 END IF;
 prefix := substring(source FROM source_start FOR lines_start-source_start);
 lines := substring(source FROM lines_start FOR source_end-lines_start);
 IF prefix NOT LIKE '%queue.created_at >= p_from%' OR lines NOT LIKE '%was_corrected%'
  OR (length(lines)-length(replace(lines,E'SELECT\n      COALESCE(','')))
    /length(E'SELECT\n      COALESCE(')<>3 THEN
  RAISE EXCEPTION 'PAPERLESS_BOTTLENECK_SAMPLE_CHANGED';
 END IF;
 prefix := replace(prefix,'queue.created_at >= p_from','queue.created_at >= p_from - (p_to-p_from)');
 prefix := replace(prefix,'DISTINCT ON (queue.order_id)',
  'DISTINCT ON (queue.order_id, (queue.created_at >= p_from))');
 prefix := replace(prefix,'ORDER BY queue.order_id, queue.created_at, queue.id',
  'ORDER BY queue.order_id, (queue.created_at >= p_from), queue.created_at, queue.id');
 prefix := replace(prefix,'queue.id AS queue_id,',
  'queue.id AS queue_id, COALESCE((to_jsonb(queue)->>''kitchen_direct_to_floor'')::boolean,false) AS direct_to_floor,');
 parts := string_to_array(lines,E'\n    UNION ALL\n');
 IF cardinality(parts)<>3 THEN RAISE EXCEPTION 'PAPERLESS_BOTTLENECK_BRANCH_CHANGED'; END IF;
 FOR i IN 1..3 LOOP
  piece := E'      scoped.received_at AS cohort_at, order_item.created_at AS received_at,\n'
   || E'      item.id::text AS sample_key, scoped.order_id,\n'
   || CASE WHEN i=3 THEN E'      ''floor_direct''::text AS workflow, NULL::timestamptz AS kitchen_done_at, NULL::timestamptz AS handoff_at,\n'
      ELSE E'      CASE WHEN scoped.direct_to_floor THEN ''kitchen_direct_to_floor'' ELSE ''kitchen_tray_floor'' END AS workflow, events.kitchen_done_at, events.tray_dispatched_at AS handoff_at,\n' END
   || E'      events.floor_served_at AS served_at,\n';
  parts[i] := replace(parts[i],E'SELECT\n      COALESCE(',E'SELECT\n'||piece||E'      COALESCE(');
 END LOOP;
 lines := array_to_string(parts,E'\n    UNION ALL\n');
 EXECUTE replace($definition$
CREATE OR REPLACE FUNCTION public.get_paperless_bottleneck_analysis(
 p_store_id uuid, p_from timestamptz, p_to timestamptz,
 p_stage text DEFAULT 'kitchen', p_hour integer DEFAULT NULL,
 p_menu_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,auth,pg_catalog AS $body$
DECLARE v_result jsonb; v_unit text;
BEGIN
 IF p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_from>=p_to
  OR p_to>p_from+interval '366 days' OR p_stage IS NULL
  OR p_stage NOT IN ('kitchen','handoff','floor') OR p_hour NOT BETWEEN 0 AND 23
  OR length(p_menu_key)>240 THEN RAISE EXCEPTION 'PAPERLESS_REPORT_RANGE_INVALID'; END IF;
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'PAPERLESS_BOTTLENECK_AUTH_REQUIRED'; END IF;
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 v_unit:=CASE WHEN p_to-p_from<=interval '14 days' THEN 'day'
  WHEN p_to-p_from<=interval '84 days' THEN 'week' ELSE 'month' END;
 __SOURCE__,
 completed AS MATERIALIZED (
  SELECT *,cohort_at>=p_from AS current_period,
   extract(hour FROM received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::integer AS hour
  FROM menu_line_durations WHERE operation_seconds>=0
   AND(kitchen_seconds IS NULL OR kitchen_seconds>=0)
   AND(tray_seconds IS NULL OR tray_seconds>=0)
   AND(floor_seconds IS NULL OR floor_seconds>=0)
 ),
 stage_samples AS MATERIALIZED (
  SELECT sample.*,stage.stage,stage.seconds
  FROM completed sample CROSS JOIN LATERAL (VALUES
   ('kitchen',sample.kitchen_seconds),
   ('handoff',CASE WHEN sample.workflow='kitchen_direct_to_floor' THEN NULL ELSE sample.tray_seconds END),
   ('floor',CASE WHEN sample.workflow='kitchen_direct_to_floor' THEN
     extract(epoch FROM (sample.served_at-sample.kitchen_done_at)) ELSE sample.floor_seconds END)
  ) stage(stage,seconds) WHERE stage.seconds>=0
 ),
 stage_metrics AS MATERIALIZED (
  SELECT stage,hour,grouping(hour) AS all_hours,
   count(*) FILTER(WHERE current_period)::integer AS current_count,
   count(*) FILTER(WHERE NOT current_period)::integer AS baseline_count,
   round(avg(seconds) FILTER(WHERE current_period))::integer AS current_mean,
   round(avg(seconds) FILTER(WHERE NOT current_period))::integer AS baseline_mean,
   CASE WHEN count(*) FILTER(WHERE current_period)>=20 THEN
    round((percentile_cont(.9) WITHIN GROUP(ORDER BY seconds)
      FILTER(WHERE current_period))::numeric)::integer END AS current_p90,
   CASE WHEN count(*) FILTER(WHERE NOT current_period)>=20 THEN
    round((percentile_cont(.9) WITHIN GROUP(ORDER BY seconds)
      FILTER(WHERE NOT current_period))::numeric)::integer END AS baseline_p90
  FROM stage_samples GROUP BY GROUPING SETS((stage),(stage,hour))
 ),
 selected AS MATERIALIZED (
  SELECT * FROM stage_samples WHERE stage=p_stage AND(p_hour IS NULL OR hour=p_hour)
 ),
 menu_metrics AS MATERIALIZED (
  SELECT menu_key,
   COALESCE(max(name_ko) FILTER(WHERE was_corrected),max(name_ko)) AS name_ko,
   COALESCE(max(name_vi) FILTER(WHERE was_corrected),max(name_vi)) AS name_vi,
   COALESCE(max(name_en) FILTER(WHERE was_corrected),max(name_en)) AS name_en,
   count(*) FILTER(WHERE current_period)::integer AS current_count,
   count(*) FILTER(WHERE NOT current_period)::integer AS baseline_count,
   avg(seconds) FILTER(WHERE current_period) AS current_mean,
   avg(seconds) FILTER(WHERE NOT current_period) AS baseline_mean
  FROM selected GROUP BY menu_key
 ),
 ranked_menus AS (
  SELECT *,CASE WHEN current_count>=5 AND baseline_count>=5 THEN
   greatest(0,(current_mean-baseline_mean)*current_count) ELSE NULL END AS extra_seconds
  FROM menu_metrics WHERE current_count>0
 ),
 selected_menu AS MATERIALIZED (
  SELECT * FROM selected WHERE p_menu_key IS NULL OR menu_key=p_menu_key
 ),
 points AS (
  SELECT date_trunc(v_unit,cohort_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS date,
   count(*)::integer AS count,round(avg(seconds))::integer AS mean,
   CASE WHEN count(*)>=20 THEN round((percentile_cont(.9)
    WITHIN GROUP(ORDER BY seconds))::numeric)::integer END AS p90
  FROM selected_menu WHERE current_period GROUP BY 1
 ),
 detail AS (
  SELECT * FROM selected_menu WHERE current_period AND p_menu_key IS NOT NULL
  ORDER BY seconds DESC,sample_key LIMIT 30
 )
 SELECT jsonb_build_object(
  'baseline_from',((p_from-(p_to-p_from)) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
  'baseline_to',((p_from-interval '1 microsecond') AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
  'bucket_unit',v_unit,
  'stages',COALESCE((SELECT jsonb_agg(to_jsonb(metric) ORDER BY stage)
    FROM stage_metrics metric WHERE all_hours=1),'[]'::jsonb),
  'hours',COALESCE((SELECT jsonb_agg(to_jsonb(metric) ORDER BY stage,hour)
    FROM stage_metrics metric WHERE all_hours=0),'[]'::jsonb),
  'menus',COALESCE((SELECT jsonb_agg(to_jsonb(metric)) FROM(
    SELECT menu_key,name_ko,name_vi,name_en,current_count,baseline_count,
     round(current_mean)::integer AS current_mean,round(baseline_mean)::integer AS baseline_mean,
     round(extra_seconds)::bigint AS extra_seconds
    FROM ranked_menus ORDER BY extra_seconds DESC NULLS LAST,current_count DESC,menu_key LIMIT 20
   ) metric),'[]'::jsonb),
  'menu_count',(SELECT count(*) FROM ranked_menus),
  'points',COALESCE((SELECT jsonb_agg(to_jsonb(point) ORDER BY date) FROM points point),'[]'::jsonb),
  'baseline',jsonb_build_object('count',(SELECT count(*) FROM selected_menu WHERE NOT current_period),
    'mean',(SELECT round(avg(seconds))::integer FROM selected_menu WHERE NOT current_period),
    'p90',(SELECT CASE WHEN count(*)>=20 THEN round((percentile_cont(.9)
      WITHIN GROUP(ORDER BY seconds))::numeric)::integer END FROM selected_menu WHERE NOT current_period)),
  'samples',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'sample_key',sample_key,'order_id',order_id,'workflow',workflow,
    'received_at',received_at,'kitchen_done_at',kitchen_done_at,
    'handoff_at',CASE WHEN workflow='kitchen_direct_to_floor' THEN NULL ELSE handoff_at END,
    'served_at',served_at,'seconds',round(seconds)::integer) ORDER BY seconds DESC,sample_key)
   FROM detail),'[]'::jsonb),
  'sample_count',(SELECT count(*) FROM selected_menu WHERE current_period AND p_menu_key IS NOT NULL),
  'completed_count',(SELECT count(*) FROM completed WHERE current_period),
  'direct_to_floor_count',(SELECT count(*) FROM completed WHERE current_period AND workflow='kitchen_direct_to_floor'),
  'floor_direct_count',(SELECT count(*) FROM completed WHERE current_period AND workflow='floor_direct')
 ) INTO v_result;
 RETURN v_result;
END;$body$;
$definition$,'__SOURCE__',prefix||lines);
END;$migration$;
REVOKE ALL ON FUNCTION public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text) TO authenticated;
COMMENT ON FUNCTION public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text) IS
 'Admin-only batched completed-line bottleneck candidates; fixed prior period, Vietnam receipt hours, P90 requires 20 samples, comparisons require 5. Extra seconds are a descriptive menu-mix measure, not labor savings or causal attribution. At most 72 stage/hour cells, 20 menus, 30 event timelines; no live backlog or configured SLA claim.';
DO $verify$
DECLARE source text;
BEGIN
 SELECT pg_get_functiondef('public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text)'::regprocedure) INTO source;
 IF source NOT LIKE '%auth.uid() IS NULL%' OR source NOT LIKE '%require_admin_actor_for_restaurant(p_store_id)%'
  OR source NOT LIKE '%stage_samples AS MATERIALIZED%' OR source NOT LIKE '%kitchen_direct_to_floor%'
  OR has_function_privilege('anon','public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text)','EXECUTE')
  OR NOT has_function_privilege('authenticated','public.get_paperless_bottleneck_analysis(uuid,timestamptz,timestamptz,text,integer,text)','EXECUTE') THEN
  RAISE EXCEPTION 'PAPERLESS_BOTTLENECK_VERIFICATION_FAILED';
 END IF;
END;$verify$;
COMMIT;
