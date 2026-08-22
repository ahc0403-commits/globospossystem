BEGIN;

-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.get_paperless_operations_insights_report(
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
  v_menu_times jsonb;
  v_category_times jsonb;
BEGIN
  -- The established report remains the source of truth for event timing,
  -- authorization, range validation, and legacy response fields.
  v_base := public.get_paperless_operations_report(
    p_store_id,
    p_from,
    p_to
  );

  SELECT COALESCE(jsonb_agg(enriched.metric ORDER BY enriched.ordinality),
    '[]'::jsonb)
  INTO v_menu_times
  FROM (
    SELECT entry.ordinality,
      entry.metric || jsonb_build_object(
        'category_key', COALESCE(category.id::text, 'uncategorized'),
        'category_name_ko', COALESCE(
          NULLIF(category.name_ko, ''),
          NULLIF(category.name, ''),
          '미분류'
        ),
        'category_name_vi', COALESCE(
          NULLIF(category.name_vi, ''),
          NULLIF(category.name, ''),
          'Chưa phân loại'
        ),
        'category_name_en', COALESCE(
          NULLIF(category.name_en, ''),
          NULLIF(category.name, ''),
          'Uncategorized'
        )
      ) AS metric
    FROM jsonb_array_elements(COALESCE(
      v_base -> 'menu_operation_times',
      '[]'::jsonb
    )) WITH ORDINALITY AS entry(metric, ordinality)
    LEFT JOIN public.menu_items menu
      ON menu.id::text = entry.metric ->> 'menu_key'
     AND menu.restaurant_id = p_store_id
    LEFT JOIN public.menu_categories category
      ON category.id = menu.category_id
     AND category.restaurant_id = p_store_id
  ) enriched;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'category_key', ranked.category_key,
    'name_ko', ranked.name_ko,
    'name_vi', ranked.name_vi,
    'name_en', ranked.name_en,
    'sample_count', ranked.sample_count,
    'operation_average_seconds', ranked.operation_average_seconds
  ) ORDER BY ranked.operation_average_seconds DESC, ranked.name_ko),
    '[]'::jsonb)
  INTO v_category_times
  FROM (
    SELECT
      metric ->> 'category_key' AS category_key,
      max(metric ->> 'category_name_ko') AS name_ko,
      max(metric ->> 'category_name_vi') AS name_vi,
      max(metric ->> 'category_name_en') AS name_en,
      sum((metric ->> 'sample_count')::integer)::integer AS sample_count,
      round(
        sum(
          (metric ->> 'operation_average_seconds')::numeric
          * (metric ->> 'sample_count')::numeric
        ) / NULLIF(sum((metric ->> 'sample_count')::numeric), 0)
      )::integer AS operation_average_seconds
    FROM jsonb_array_elements(v_menu_times) metric
    WHERE (metric ->> 'sample_count')::integer > 0
      AND (metric ->> 'operation_average_seconds')::integer >= 0
    GROUP BY metric ->> 'category_key'
  ) ranked;

  RETURN (v_base - 'menu_operation_times') || jsonb_build_object(
    'menu_operation_times', v_menu_times,
    'category_operation_times', v_category_times
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_paperless_operations_insights_report(
  uuid, timestamptz, timestamptz
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_paperless_operations_insights_report(
  uuid, timestamptz, timestamptz
) TO authenticated;

COMMENT ON FUNCTION public.get_paperless_operations_insights_report(
  uuid, timestamptz, timestamptz
) IS
  'Adds localized, sample-weighted category service-time metrics to the established paperless operations report.';

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_paperless_operations_insights_report(uuid,timestamp with time zone,timestamp with time zone)'
      ::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%get_paperless_operations_report%'
     OR v_definition NOT LIKE '%category_operation_times%'
     OR v_definition NOT LIKE '%category_name_ko%'
     OR v_definition NOT LIKE '%operation_average_seconds%'
     OR v_definition NOT LIKE '%sample_count%' THEN
    RAISE EXCEPTION 'PAPERLESS_OPERATIONS_INSIGHTS_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_paperless_operations_insights_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_paperless_operations_insights_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_OPERATIONS_INSIGHTS_PRIVILEGE_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
