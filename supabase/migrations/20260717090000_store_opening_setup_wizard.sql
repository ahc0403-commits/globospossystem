BEGIN;

-- Store-opening setup is deliberately additive. Existing tables and printer
-- destinations are never removed or deactivated by this migration or its RPCs.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.printer_destinations
    WHERE is_active = true
    GROUP BY restaurant_id, lower(btrim(purpose)),
      COALESCE(upper(btrim(floor_label)), '')
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'STORE_SETUP_DUPLICATE_ACTIVE_ROUTE_PREFLIGHT';
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS printer_destinations_active_route_unique
  ON public.printer_destinations (
    restaurant_id,
    lower(btrim(purpose)),
    (COALESCE(upper(btrim(floor_label)), ''))
  )
  WHERE is_active = true;

CREATE OR REPLACE FUNCTION public.store_opening_private_ipv4(p_value text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
DECLARE
  v_parts text[];
  v_first int;
  v_second int;
BEGIN
  IF p_value !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
    RETURN false;
  END IF;
  v_parts := pg_catalog.string_to_array(p_value, '.');
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.unnest(v_parts) AS part(value)
    WHERE value::int NOT BETWEEN 0 AND 255
  ) THEN
    RETURN false;
  END IF;
  v_first := v_parts[1]::int;
  v_second := v_parts[2]::int;
  RETURN v_first = 10
    OR (v_first = 172 AND v_second BETWEEN 16 AND 31)
    OR (v_first = 192 AND v_second = 168);
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_validate_store_opening_config(
  p_store_id uuid,
  p_tables jsonb,
  p_destinations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_table_count int := 0;
  v_destination_count int := 0;
  v_tables_create int := 0;
  v_tables_update int := 0;
  v_destinations_create int := 0;
  v_destinations_update int := 0;
  v_untouched_tables int := 0;
  v_untouched_destinations int := 0;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id = p_store_id) THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_NOT_FOUND';
  END IF;

  IF p_tables IS NULL OR jsonb_typeof(p_tables) <> 'array' THEN
    v_errors := v_errors || jsonb_build_array('STORE_SETUP_TABLES_ARRAY_REQUIRED');
  ELSE
    v_table_count := jsonb_array_length(p_tables);
    IF v_table_count = 0 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_TABLES_REQUIRED');
    ELSIF v_table_count > 500 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_TABLE_LIMIT');
    END IF;
  END IF;

  IF p_destinations IS NULL OR jsonb_typeof(p_destinations) <> 'array' THEN
    v_errors := v_errors || jsonb_build_array('STORE_SETUP_DESTINATIONS_ARRAY_REQUIRED');
  ELSE
    v_destination_count := jsonb_array_length(p_destinations);
    IF v_destination_count = 0 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DESTINATIONS_REQUIRED');
    ELSIF v_destination_count > 20 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DESTINATION_LIMIT');
    END IF;
  END IF;

  IF jsonb_typeof(COALESCE(p_tables, 'null'::jsonb)) = 'array'
     AND jsonb_array_length(v_errors) = 0 THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      WHERE jsonb_typeof(value) <> 'object'
        OR NULLIF(btrim(value->>'table_number'), '') IS NULL
        OR length(btrim(value->>'table_number')) > 32
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_TABLE_NUMBER_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      WHERE COALESCE(value->>'seat_count', '') !~ '^[0-9]+$'
        OR CASE WHEN COALESCE(value->>'seat_count', '') ~ '^[0-9]+$'
          THEN (value->>'seat_count')::numeric NOT BETWEEN 1 AND 100
          ELSE false END
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_SEAT_COUNT_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      WHERE NULLIF(btrim(value->>'floor_label'), '') IS NULL
        OR upper(btrim(value->>'floor_label')) !~ '^[A-Z0-9][A-Z0-9 _-]{0,15}$'
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_FLOOR_LABEL_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      GROUP BY upper(btrim(value->>'table_number'))
      HAVING count(*) > 1
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DUPLICATE_TABLE_NUMBER');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      JOIN public.tables t
        ON t.restaurant_id = p_store_id
       AND upper(btrim(t.table_number)) = upper(btrim(value->>'table_number'))
      GROUP BY upper(btrim(value->>'table_number'))
      HAVING count(t.id) > 1
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_EXISTING_TABLE_IDENTITY_AMBIGUOUS');
    END IF;
    IF jsonb_array_length(v_errors) = 0 AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_tables) row(value)
      JOIN public.tables t
        ON t.restaurant_id = p_store_id
       AND upper(btrim(t.table_number)) = upper(btrim(value->>'table_number'))
      WHERE t.status IN ('occupied', 'reserved')
        AND (
          upper(btrim(t.floor_label)) IS DISTINCT FROM upper(btrim(value->>'floor_label'))
        OR t.seat_count IS DISTINCT FROM CASE
          WHEN COALESCE(value->>'seat_count', '') ~ '^[0-9]+$'
            THEN (value->>'seat_count')::int
          ELSE t.seat_count
        END
        )
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_OCCUPIED_TABLE_CHANGE');
    END IF;
  END IF;

  IF jsonb_typeof(COALESCE(p_destinations, 'null'::jsonb)) = 'array'
     AND jsonb_array_length(v_errors) = 0 THEN
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE jsonb_typeof(value) <> 'object'
        OR NULLIF(btrim(value->>'name'), '') IS NULL
        OR length(btrim(value->>'name')) > 80
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DESTINATION_NAME_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE NULLIF(btrim(value->>'purpose'), '') IS NULL
        OR lower(btrim(value->>'purpose')) NOT IN ('receipt', 'kitchen', 'floor', 'tray')
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_PURPOSE_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE NULLIF(btrim(value->>'ip'), '') IS NULL
        OR NOT COALESCE(public.store_opening_private_ipv4(btrim(value->>'ip')), false)
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_IP_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE COALESCE(value->>'port', '') !~ '^[0-9]+$'
        OR CASE WHEN COALESCE(value->>'port', '') ~ '^[0-9]+$'
          THEN (value->>'port')::numeric NOT BETWEEN 1 AND 65535
          ELSE false END
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_PORT_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE lower(btrim(value->>'purpose')) = 'floor'
        AND (
          NULLIF(btrim(value->>'floor_label'), '') IS NULL
          OR upper(btrim(value->>'floor_label')) !~ '^[A-Z0-9][A-Z0-9 _-]{0,15}$'
        )
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DESTINATION_FLOOR_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_destinations) row(value)
      GROUP BY lower(btrim(value->>'purpose')),
        CASE WHEN lower(btrim(value->>'purpose')) = 'floor'
          THEN upper(btrim(value->>'floor_label')) ELSE '' END
      HAVING count(*) > 1
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_DUPLICATE_ROUTE');
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(p_destinations) row(value)
        WHERE lower(btrim(value->>'purpose')) = 'receipt') <> 1 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_RECEIPT_ROUTE_REQUIRED');
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(p_destinations) row(value)
        WHERE lower(btrim(value->>'purpose')) = 'kitchen') <> 1 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_KITCHEN_ROUTE_REQUIRED');
    END IF;
    IF jsonb_typeof(COALESCE(p_tables, 'null'::jsonb)) = 'array' AND EXISTS (
      SELECT 1
      FROM (
        SELECT DISTINCT upper(btrim(value->>'floor_label')) AS floor_label
        FROM jsonb_array_elements(p_tables) row(value)
        WHERE NULLIF(btrim(value->>'floor_label'), '') IS NOT NULL
      ) floors
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_destinations) destination(value)
        WHERE lower(btrim(value->>'purpose')) = 'floor'
          AND upper(btrim(value->>'floor_label')) = floors.floor_label
      )
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_FLOOR_ROUTE_REQUIRED');
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_destinations) row(value)
      JOIN public.printer_destinations d
        ON d.restaurant_id = p_store_id
       AND d.is_active = false
       AND lower(btrim(d.purpose)) = lower(btrim(value->>'purpose'))
       AND COALESCE(upper(btrim(d.floor_label)), '') = CASE
         WHEN lower(btrim(value->>'purpose')) = 'floor'
           THEN upper(btrim(value->>'floor_label')) ELSE '' END
      WHERE NOT EXISTS (
        SELECT 1 FROM public.printer_destinations active_d
        WHERE active_d.restaurant_id = p_store_id
          AND active_d.is_active = true
          AND lower(btrim(active_d.purpose)) = lower(btrim(value->>'purpose'))
          AND COALESCE(upper(btrim(active_d.floor_label)), '') = CASE
            WHEN lower(btrim(value->>'purpose')) = 'floor'
              THEN upper(btrim(value->>'floor_label')) ELSE '' END
      )
      GROUP BY lower(btrim(value->>'purpose')),
        CASE WHEN lower(btrim(value->>'purpose')) = 'floor'
          THEN upper(btrim(value->>'floor_label')) ELSE '' END
      HAVING count(d.id) > 1
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_MULTIPLE_INACTIVE_ROUTE_MATCHES');
    END IF;
  END IF;

  IF jsonb_typeof(COALESCE(p_tables, 'null'::jsonb)) = 'array'
     AND jsonb_array_length(v_errors) = 0 THEN
    SELECT
      count(*) FILTER (WHERE t.id IS NULL),
      count(*) FILTER (WHERE t.id IS NOT NULL AND (
        t.seat_count IS DISTINCT FROM (row.value->>'seat_count')::int
        OR upper(btrim(t.floor_label)) IS DISTINCT FROM upper(btrim(row.value->>'floor_label'))
      )),
      GREATEST((SELECT count(*) FROM public.tables WHERE restaurant_id = p_store_id) - count(t.id), 0)
    INTO v_tables_create, v_tables_update, v_untouched_tables
    FROM jsonb_array_elements(p_tables) row(value)
    LEFT JOIN public.tables t
      ON t.restaurant_id = p_store_id
     AND upper(btrim(t.table_number)) = upper(btrim(row.value->>'table_number'))
    WHERE COALESCE(row.value->>'seat_count', '') ~ '^[0-9]+$';
  END IF;

  IF jsonb_typeof(COALESCE(p_destinations, 'null'::jsonb)) = 'array'
     AND jsonb_array_length(v_errors) = 0 THEN
    WITH submitted AS (
      SELECT value,
        lower(btrim(value->>'purpose')) AS purpose,
        CASE WHEN lower(btrim(value->>'purpose')) = 'floor'
          THEN upper(btrim(value->>'floor_label')) ELSE '' END AS floor_key
      FROM jsonb_array_elements(p_destinations) row(value)
    ), matches AS (
      SELECT s.*, d.id, d.name, d.ip, d.port, d.is_active,
        row_number() OVER (
          PARTITION BY s.purpose, s.floor_key
          ORDER BY d.is_active DESC, d.created_at, d.id
        ) AS match_rank
      FROM submitted s
      LEFT JOIN public.printer_destinations d
        ON d.restaurant_id = p_store_id
       AND lower(btrim(d.purpose)) = s.purpose
       AND COALESCE(upper(btrim(d.floor_label)), '') = s.floor_key
    )
    SELECT
      count(*) FILTER (WHERE id IS NULL),
      count(*) FILTER (WHERE id IS NOT NULL AND (
        name IS DISTINCT FROM btrim(value->>'name')
        OR ip IS DISTINCT FROM btrim(value->>'ip')
        OR port IS DISTINCT FROM (value->>'port')::int
        OR is_active IS DISTINCT FROM true
      )),
      GREATEST(
        (SELECT count(*) FROM public.printer_destinations WHERE restaurant_id = p_store_id)
        - count(id), 0
      )
    INTO v_destinations_create, v_destinations_update, v_untouched_destinations
    FROM matches
    WHERE match_rank = 1
      AND COALESCE(value->>'port', '') ~ '^[0-9]+$';
  END IF;

  IF v_untouched_tables > 0 THEN
    v_warnings := v_warnings || jsonb_build_array('STORE_SETUP_EXISTING_TABLES_UNTOUCHED');
  END IF;
  IF v_untouched_destinations > 0 THEN
    v_warnings := v_warnings || jsonb_build_array('STORE_SETUP_EXISTING_ROUTES_UNTOUCHED');
  END IF;

  RETURN jsonb_build_object(
    'valid', jsonb_array_length(v_errors) = 0,
    'errors', v_errors,
    'warnings', v_warnings,
    'plan', jsonb_build_object(
      'tables_create', v_tables_create,
      'tables_update', v_tables_update,
      'destinations_create', v_destinations_create,
      'destinations_update', v_destinations_update,
      'untouched_existing_tables', v_untouched_tables,
      'untouched_existing_destinations', v_untouched_destinations
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_store_opening_config(
  p_store_id uuid,
  p_tables jsonb,
  p_destinations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_validation jsonb;
  v_store public.restaurants%ROWTYPE;
  v_row jsonb;
  v_existing public.tables%ROWTYPE;
  v_existing_destination public.printer_destinations%ROWTYPE;
  v_destination_found boolean;
  v_desired_floor_key text;
  v_table_rows jsonb;
  v_destination_rows jsonb;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_NOT_FOUND';
  END IF;

  v_validation := public.admin_validate_store_opening_config(
    p_store_id, p_tables, p_destinations
  );
  IF NOT COALESCE((v_validation->>'valid')::boolean, false) THEN
    RAISE EXCEPTION USING
      MESSAGE = 'STORE_SETUP_CONFIG_INVALID',
      DETAIL = (v_validation->'errors')::text;
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_tables) row(value)
  LOOP
    SELECT * INTO v_existing
    FROM public.tables
    WHERE restaurant_id = p_store_id
      AND upper(btrim(table_number)) = upper(btrim(v_row->>'table_number'))
    FOR UPDATE;

    IF FOUND THEN
      IF v_existing.seat_count IS DISTINCT FROM (v_row->>'seat_count')::int
         OR upper(btrim(v_existing.floor_label)) IS DISTINCT FROM upper(btrim(v_row->>'floor_label')) THEN
        PERFORM public.admin_update_table(
          v_existing.id, p_store_id, v_existing.table_number,
          (v_row->>'seat_count')::int, NULL, NULL, NULL, NULL, NULL,
          NULL, NULL, NULL, upper(btrim(v_row->>'floor_label'))
        );
      END IF;
    ELSE
      PERFORM public.admin_create_table(
        p_store_id,
        btrim(v_row->>'table_number'),
        (v_row->>'seat_count')::int,
        upper(btrim(v_row->>'floor_label'))
      );
    END IF;
  END LOOP;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_destinations) row(value)
  LOOP
    SELECT * INTO v_existing_destination
    FROM public.printer_destinations
    WHERE restaurant_id = p_store_id
      AND lower(btrim(purpose)) = lower(btrim(v_row->>'purpose'))
      AND COALESCE(upper(btrim(floor_label)), '') = CASE
        WHEN lower(btrim(v_row->>'purpose')) = 'floor'
          THEN upper(btrim(v_row->>'floor_label')) ELSE '' END
    ORDER BY is_active DESC, created_at, id
    LIMIT 1
    FOR UPDATE;

    v_destination_found := FOUND;
    v_desired_floor_key := CASE
      WHEN lower(btrim(v_row->>'purpose')) = 'floor'
        THEN upper(btrim(v_row->>'floor_label'))
      ELSE ''
    END;

    IF NOT v_destination_found
       OR v_existing_destination.name IS DISTINCT FROM btrim(v_row->>'name')
       OR v_existing_destination.ip IS DISTINCT FROM btrim(v_row->>'ip')
       OR v_existing_destination.port IS DISTINCT FROM (v_row->>'port')::int
       OR v_existing_destination.is_active IS DISTINCT FROM true
       OR COALESCE(upper(btrim(v_existing_destination.floor_label)), '')
          IS DISTINCT FROM v_desired_floor_key THEN
      PERFORM public.admin_upsert_printer_destination(
        p_store_id,
        CASE WHEN v_existing_destination.id IS NULL
          THEN NULL ELSE v_existing_destination.id END,
        btrim(v_row->>'name'),
        btrim(v_row->>'ip'),
        (v_row->>'port')::int,
        lower(btrim(v_row->>'purpose')),
        CASE WHEN lower(btrim(v_row->>'purpose')) = 'floor'
          THEN upper(btrim(v_row->>'floor_label')) ELSE NULL END,
        true
      );
    END IF;
    v_existing_destination := NULL;
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.table_number), '[]'::jsonb)
  INTO v_table_rows
  FROM public.tables t
  WHERE t.restaurant_id = p_store_id;

  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.purpose, d.floor_label, d.name), '[]'::jsonb)
  INTO v_destination_rows
  FROM public.printer_destinations d
  WHERE d.restaurant_id = p_store_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_apply_store_opening_config',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'summary_counts', v_validation->'plan',
      'submitted_table_count', jsonb_array_length(p_tables),
      'submitted_destination_count', jsonb_array_length(p_destinations),
      'updated_at_utc', now()
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'plan', v_validation->'plan',
    'tables', v_table_rows,
    'destinations', v_destination_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_store_opening_readiness(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_checks jsonb := '[]'::jsonb;
  v_tests jsonb := '[]'::jsonb;
  v_recovery jsonb := '[]'::jsonb;
  v_table_count int;
  v_blank_floor_count int;
  v_missing_route_count int;
  v_duplicate_route_count int;
  v_pending_count int;
  v_failed_count int;
  v_no_destination_count int;
  v_required_count int;
  v_done_test_count int;
  v_configured_at timestamptz;
  v_config_ready boolean;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id = p_store_id) THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_NOT_FOUND';
  END IF;

  SELECT count(*), count(*) FILTER (
    WHERE NULLIF(btrim(COALESCE(floor_label, '')), '') IS NULL
  ) INTO v_table_count, v_blank_floor_count
  FROM public.tables
  WHERE restaurant_id = p_store_id;

  WITH required_routes AS (
    SELECT 'receipt'::text AS purpose, ''::text AS floor_key
    UNION ALL SELECT 'kitchen', ''
    UNION ALL
    SELECT DISTINCT 'floor', upper(btrim(floor_label))
    FROM public.tables
    WHERE restaurant_id = p_store_id
      AND NULLIF(btrim(COALESCE(floor_label, '')), '') IS NOT NULL
  ), active_routes AS (
    SELECT lower(btrim(purpose)) AS purpose,
      COALESCE(upper(btrim(floor_label)), '') AS floor_key,
      count(*) AS route_count
    FROM public.printer_destinations
    WHERE restaurant_id = p_store_id AND is_active = true
    GROUP BY lower(btrim(purpose)), COALESCE(upper(btrim(floor_label)), '')
  )
  SELECT count(*) FILTER (WHERE COALESCE(a.route_count, 0) <> 1)
  INTO v_missing_route_count
  FROM required_routes r
  LEFT JOIN active_routes a USING (purpose, floor_key);

  SELECT count(*) INTO v_duplicate_route_count
  FROM (
    SELECT 1
    FROM public.printer_destinations
    WHERE restaurant_id = p_store_id AND is_active = true
    GROUP BY lower(btrim(purpose)), COALESCE(upper(btrim(floor_label)), '')
    HAVING count(*) > 1
  ) duplicates;

  SELECT GREATEST(
    COALESCE(max(updated_at), '-infinity'::timestamptz),
    COALESCE((SELECT max(updated_at) FROM public.tables WHERE restaurant_id = p_store_id), '-infinity'::timestamptz)
  ) INTO v_configured_at
  FROM public.printer_destinations
  WHERE restaurant_id = p_store_id;

  SELECT
    count(*) FILTER (WHERE status IN ('pending', 'printing')),
    count(*) FILTER (WHERE status = 'failed'),
    count(*) FILTER (
      WHERE last_error = 'NO_DESTINATION'
        AND created_at >= v_configured_at
    )
  INTO v_pending_count, v_failed_count, v_no_destination_count
  FROM public.print_jobs
  WHERE restaurant_id = p_store_id;

  WITH required_destinations AS (
    SELECT d.id, d.purpose,
      COALESCE(upper(btrim(d.floor_label)), '') AS floor_key,
      d.updated_at
    FROM public.printer_destinations d
    WHERE d.restaurant_id = p_store_id
      AND d.is_active = true
      AND (
        d.purpose IN ('receipt', 'kitchen')
        OR (d.purpose = 'floor' AND EXISTS (
          SELECT 1 FROM public.tables t
          WHERE t.restaurant_id = p_store_id
            AND upper(btrim(t.floor_label)) = upper(btrim(d.floor_label))
        ))
      )
  ), latest_tests AS (
    SELECT r.*,
      j.id AS job_id,
      j.status,
      j.last_error,
      j.created_at AS tested_at
    FROM required_destinations r
    LEFT JOIN LATERAL (
      SELECT pj.id, pj.status, pj.last_error, pj.created_at
      FROM public.print_jobs pj
      WHERE pj.restaurant_id = p_store_id
        AND pj.destination_id = r.id
        AND pj.payload->>'printed_reason' = 'test_print'
        AND pj.created_at >= r.updated_at
      ORDER BY pj.created_at DESC, pj.id DESC
      LIMIT 1
    ) j ON true
  )
  SELECT count(*), count(*) FILTER (WHERE status = 'done'),
    COALESCE(jsonb_agg(jsonb_build_object(
      'destination_id', id,
      'label', upper(purpose) || CASE WHEN floor_key = '' THEN '' ELSE '-' || floor_key END,
      'job_id', job_id,
      'status', COALESCE(status, 'missing'),
      'last_error', last_error,
      'tested_at', tested_at
    ) ORDER BY purpose, floor_key), '[]'::jsonb)
  INTO v_required_count, v_done_test_count, v_tests
  FROM latest_tests;

  v_config_ready := v_table_count > 0
    AND v_blank_floor_count = 0
    AND v_missing_route_count = 0
    AND v_duplicate_route_count = 0
    AND v_no_destination_count = 0;

  v_checks := jsonb_build_array(
    jsonb_build_object('code', 'TABLES_CONFIGURED', 'ok', v_table_count > 0, 'count', v_table_count),
    jsonb_build_object('code', 'TABLE_FLOORS_VALID', 'ok', v_blank_floor_count = 0, 'count', v_blank_floor_count),
    jsonb_build_object('code', 'REQUIRED_ROUTES_CONFIGURED', 'ok', v_missing_route_count = 0, 'count', v_missing_route_count),
    jsonb_build_object('code', 'ACTIVE_ROUTES_UNIQUE', 'ok', v_duplicate_route_count = 0, 'count', v_duplicate_route_count),
    jsonb_build_object('code', 'NO_DESTINATION_CLEAR', 'ok', v_no_destination_count = 0, 'count', v_no_destination_count),
    jsonb_build_object('code', 'TEST_JOBS_DONE', 'ok', v_required_count > 0 AND v_done_test_count = v_required_count, 'count', v_done_test_count, 'required', v_required_count)
  );

  IF NOT v_config_ready THEN
    v_recovery := v_recovery || jsonb_build_array('STORE_SETUP_FIX_CONFIGURATION');
  END IF;
  IF v_required_count = 0 OR v_done_test_count <> v_required_count THEN
    v_recovery := v_recovery || jsonb_build_array('STORE_SETUP_RUN_OR_RETRY_TESTS');
  END IF;
  IF v_failed_count > 0 THEN
    v_recovery := v_recovery || jsonb_build_array('STORE_SETUP_REVIEW_FAILED_JOBS');
  END IF;

  RETURN jsonb_build_object(
    'ready', v_config_ready AND v_required_count > 0 AND v_done_test_count = v_required_count,
    'config_ready', v_config_ready,
    'checks', v_checks,
    'tests', v_tests,
    'pending_jobs', v_pending_count,
    'failed_jobs', v_failed_count,
    'recovery', v_recovery,
    'configured_at', v_configured_at
  );
END;
$$;

-- The designated Windows cashier must be able to process the durable queue
-- after the configuring admin logs out. Store scope is still checked by the
-- same server-side accessible-store boundary.
CREATE OR REPLACE FUNCTION public.print_routing_actor_can_run(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN (
        'cashier', 'kitchen', 'admin', 'store_admin', 'brand_admin', 'super_admin'
      )
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = p_store_id
        )
      )
  );
$$;

REVOKE ALL ON FUNCTION public.store_opening_private_ipv4(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_validate_store_opening_config(uuid, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_apply_store_opening_config(uuid, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_get_store_opening_readiness(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_validate_store_opening_config(uuid, jsonb, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_store_opening_config(uuid, jsonb, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_store_opening_readiness(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.admin_validate_store_opening_config(uuid, jsonb, jsonb)
  IS 'Validates a store-opening draft without mutation; admin and store scoped.';
COMMENT ON FUNCTION public.admin_apply_store_opening_config(uuid, jsonb, jsonb)
  IS 'Atomically applies an idempotent store-opening configuration without deleting or deactivating unspecified rows.';
COMMENT ON FUNCTION public.admin_get_store_opening_readiness(uuid)
  IS 'Returns informational setup and printer-test readiness; never gates orders or payment.';

COMMIT;
