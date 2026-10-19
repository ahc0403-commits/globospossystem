BEGIN;

-- production-gate: self-verifying
-- Separate paperless receipt-only setup from operational ticket printing.
-- Older setup RPC signatures remain available for installed clients.

CREATE OR REPLACE FUNCTION public.admin_validate_store_opening_config_v2(
  p_store_id uuid,
  p_tables jsonb,
  p_destinations jsonb,
  p_mode text
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

  IF p_mode IS NULL OR p_mode NOT IN ('paperless', 'pos_print') THEN
    v_errors := v_errors || jsonb_build_array('STORE_SETUP_MODE_INVALID');
  ELSIF p_mode IS DISTINCT FROM public.get_store_fulfillment_mode(p_store_id)
        AND NOT public.is_super_admin() THEN
    v_errors := v_errors || jsonb_build_array('STORE_SETUP_MODE_PERMISSION');
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
      WHERE COALESCE(value->>'connection', '') NOT IN ('wired', 'wireless', 'usb')
        OR COALESCE(value->>'physical_slot', '') NOT IN ('cashier', 'kitchen', 'floor2', 'floor3')
        OR length(COALESCE(value->>'physical_name', '')) > 80
    ) OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      GROUP BY value->>'physical_slot'
      HAVING count(DISTINCT jsonb_build_array(value->>'connection',
        CASE WHEN value->>'connection' = 'usb' THEN btrim(value->>'usb_printer_name')
          ELSE btrim(value->>'ip') END,
        CASE WHEN value->>'connection' = 'usb' THEN '9100' ELSE value->>'port' END,
        value->>'physical_name')) > 1
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_CONNECTION_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE value->>'connection' = 'usb'
        AND (NULLIF(btrim(value->>'usb_printer_name'), '') IS NULL
          OR length(btrim(value->>'usb_printer_name')) > 255)
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_USB_NAME_REQUIRED');
    END IF;
    IF p_mode = 'paperless' AND (jsonb_array_length(p_destinations) <> 1
      OR p_destinations->0->>'purpose' IS DISTINCT FROM 'receipt'
      OR p_destinations->0->>'physical_slot' IS DISTINCT FROM 'cashier') THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_PAPERLESS_RECEIPT_ONLY');
    END IF;
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
      WHERE value->>'connection' IN ('wired', 'wireless')
        AND (NULLIF(btrim(value->>'ip'), '') IS NULL
        OR NOT COALESCE(public.store_opening_private_ipv4(btrim(value->>'ip')), false))
    ) THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_IP_INVALID');
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_destinations) row(value)
      WHERE value->>'connection' <> 'usb' AND (COALESCE(value->>'port', '') !~ '^[0-9]+$'
        OR CASE WHEN COALESCE(value->>'port', '') ~ '^[0-9]+$'
          THEN (value->>'port')::numeric NOT BETWEEN 1 AND 65535
          ELSE false END)
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
    IF p_mode = 'pos_print' AND (SELECT count(*) FROM jsonb_array_elements(p_destinations) row(value)
        WHERE lower(btrim(value->>'purpose')) = 'kitchen') <> 1 THEN
      v_errors := v_errors || jsonb_build_array('STORE_SETUP_KITCHEN_ROUTE_REQUIRED');
    END IF;
    IF p_mode = 'pos_print' AND jsonb_typeof(COALESCE(p_tables, 'null'::jsonb)) = 'array' AND EXISTS (
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
    ), current_endpoints AS (
      SELECT e.physical_printer_id, count(*) AS endpoint_count,
        min(e.endpoint_type) AS connection, min(e.ip) AS endpoint_ip,
        min(e.device_name) AS device_name, min(e.port) AS endpoint_port
      FROM public.printer_endpoints e
      JOIN public.physical_printers p ON p.id = e.physical_printer_id
      WHERE p.restaurant_id = p_store_id AND e.is_active
      GROUP BY e.physical_printer_id
    ), matches AS (
      SELECT s.*, d.id, d.name, d.ip, d.port, d.is_active,
        e.endpoint_count, e.connection, e.endpoint_ip, e.device_name, e.endpoint_port,
        row_number() OVER (
          PARTITION BY s.purpose, s.floor_key
          ORDER BY d.is_active DESC, d.created_at, d.id
        ) AS match_rank
      FROM submitted s
      LEFT JOIN public.printer_destinations d
        ON d.restaurant_id = p_store_id
       AND lower(btrim(d.purpose)) = s.purpose
       AND COALESCE(upper(btrim(d.floor_label)), '') = s.floor_key
      LEFT JOIN current_endpoints e ON e.physical_printer_id = d.physical_printer_id
    )
    SELECT
      count(*) FILTER (WHERE id IS NULL),
      count(*) FILTER (WHERE id IS NOT NULL AND (
        name IS DISTINCT FROM btrim(value->>'name')
        OR ip IS DISTINCT FROM CASE WHEN value->>'connection' = 'usb' THEN '127.0.0.1' ELSE btrim(value->>'ip') END
        OR port IS DISTINCT FROM CASE WHEN value->>'connection' = 'usb' THEN 9100 ELSE (value->>'port')::int END
        OR endpoint_count IS DISTINCT FROM 1::bigint
        OR connection IS DISTINCT FROM value->>'connection'
        OR CASE WHEN value->>'connection' = 'usb'
          THEN device_name IS DISTINCT FROM btrim(value->>'usb_printer_name')
          ELSE endpoint_ip IS DISTINCT FROM btrim(value->>'ip') OR endpoint_port IS DISTINCT FROM (value->>'port')::int END
        OR is_active IS DISTINCT FROM true
      )),
      GREATEST(
        (SELECT count(*) FROM public.printer_destinations WHERE restaurant_id = p_store_id)
        - count(id), 0
      )
    INTO v_destinations_create, v_destinations_update, v_untouched_destinations
    FROM matches
    WHERE match_rank = 1;
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
  v_mode text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id = p_store_id) THEN
    RAISE EXCEPTION 'STORE_SETUP_STORE_NOT_FOUND';
  END IF;

  v_mode := public.get_store_fulfillment_mode(p_store_id);

  SELECT count(*), count(*) FILTER (
    WHERE NULLIF(btrim(COALESCE(floor_label, '')), '') IS NULL
  ) INTO v_table_count, v_blank_floor_count
  FROM public.tables
  WHERE restaurant_id = p_store_id;

  WITH required_routes AS (
    SELECT 'receipt'::text AS purpose, ''::text AS floor_key
    UNION ALL SELECT 'kitchen', '' WHERE v_mode = 'pos_print'
    UNION ALL
    SELECT DISTINCT 'floor', upper(btrim(floor_label))
    FROM public.tables
    WHERE restaurant_id = p_store_id AND v_mode = 'pos_print'
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
        AND (v_mode = 'pos_print' OR copy_type = 'receipt')
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
        d.purpose = 'receipt'
        OR (v_mode = 'pos_print' AND d.purpose = 'kitchen')
        OR (v_mode = 'pos_print' AND d.purpose = 'floor' AND EXISTS (
          SELECT 1 FROM public.tables t
          WHERE t.restaurant_id = p_store_id
            AND upper(btrim(t.floor_label)) = upper(btrim(d.floor_label))
        ))
      )
  ), ranked_tests AS (
    SELECT pj.destination_id, pj.id AS job_id, pj.status, pj.last_error,
      pj.created_at AS tested_at,
      row_number() OVER (PARTITION BY pj.destination_id ORDER BY pj.created_at DESC, pj.id DESC) AS rank
    FROM public.print_jobs pj
    JOIN required_destinations r ON r.id = pj.destination_id
    WHERE pj.restaurant_id = p_store_id
      AND pj.payload->>'printed_reason' = 'test_print'
      AND pj.created_at >= r.updated_at
  ), latest_tests AS (
    SELECT r.*, j.job_id, j.status, j.last_error, j.tested_at
    FROM required_destinations r
    LEFT JOIN ranked_tests j ON j.destination_id = r.id AND j.rank = 1
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
    'mode', v_mode,
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


CREATE OR REPLACE FUNCTION public.admin_apply_store_opening_config_v2(
  p_store_id uuid, p_tables jsonb, p_destinations jsonb, p_mode text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_validation jsonb;
  v_routes jsonb;
  v_previous_mode text;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  -- All setup writers serialize by store; existing per-table admin writers
  -- also respect the row locks acquired before validation below.
  PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:' || p_store_id::text, 0));
  PERFORM 1 FROM public.restaurants WHERE id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STORE_SETUP_STORE_NOT_FOUND'; END IF;
  PERFORM 1 FROM public.tables WHERE restaurant_id = p_store_id ORDER BY id FOR UPDATE;
  PERFORM 1 FROM public.printer_destinations WHERE restaurant_id = p_store_id ORDER BY id FOR UPDATE;

  v_validation := public.admin_validate_store_opening_config_v2(
    p_store_id, p_tables, p_destinations, p_mode);
  IF NOT COALESCE((v_validation->>'valid')::boolean, false) THEN
    RAISE EXCEPTION USING MESSAGE = 'STORE_SETUP_CONFIG_INVALID',
      DETAIL = (v_validation->'errors')::text;
  END IF;

  -- Set-based table updates retain old/new values in the existing audit format.
  WITH desired AS (
    SELECT btrim(value->>'table_number') AS table_number,
      (value->>'seat_count')::int AS seat_count,
      upper(btrim(value->>'floor_label')) AS floor_label
    FROM jsonb_array_elements(p_tables)
  ), changes AS (
    SELECT t.id, t.table_number, t.seat_count AS old_seat_count,
      t.floor_label AS old_floor_label, d.seat_count, d.floor_label
    FROM desired d JOIN public.tables t ON t.restaurant_id = p_store_id
      AND upper(btrim(t.table_number)) = upper(d.table_number)
    WHERE t.seat_count IS DISTINCT FROM d.seat_count
      OR upper(btrim(t.floor_label)) IS DISTINCT FROM d.floor_label
  ), updated AS (
    UPDATE public.tables t SET seat_count = c.seat_count,
      floor_label = c.floor_label, updated_at = now()
    FROM changes c WHERE t.id = c.id RETURNING t.id
  )
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  SELECT auth.uid(), 'admin_update_table', 'tables', c.id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now(),
      'old_values', jsonb_build_object('seat_count', c.old_seat_count, 'floor_label', c.old_floor_label),
      'new_values', jsonb_build_object('seat_count', c.seat_count, 'floor_label', c.floor_label))
  FROM changes c JOIN updated u USING (id);

  WITH desired AS (
    SELECT btrim(value->>'table_number') AS table_number,
      (value->>'seat_count')::int AS seat_count,
      upper(btrim(value->>'floor_label')) AS floor_label, ordinal
    FROM jsonb_array_elements(p_tables) WITH ORDINALITY AS entries(value, ordinal)
  ), missing AS (
    SELECT d.*, row_number() OVER (ORDER BY ordinal) - 1 AS sort_offset
    FROM desired d LEFT JOIN public.tables t ON t.restaurant_id = p_store_id
      AND upper(btrim(t.table_number)) = upper(d.table_number)
    WHERE t.id IS NULL
  ), base AS (
    SELECT COALESCE(max(layout_sort_order), -1) + 1 AS next_sort
    FROM public.tables WHERE restaurant_id = p_store_id
  ), created AS (
    INSERT INTO public.tables(restaurant_id, table_number, seat_count, status,
      floor_label, layout_x, layout_y, layout_w, layout_h, layout_rotation,
      layout_shape, layout_sort_order)
    SELECT p_store_id, m.table_number, m.seat_count, 'available', m.floor_label,
      ((next_sort + m.sort_offset) % 4) * 0.22,
      LEAST(((next_sort + m.sort_offset) / 4) * 0.18, 0.86),
      0.18, 0.14, 0, 'rectangle', next_sort + m.sort_offset
    FROM missing m CROSS JOIN base RETURNING *
  )
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  SELECT auth.uid(), 'admin_create_table', 'tables', id,
    jsonb_build_object('store_id', p_store_id, 'created_at_utc', now(), 'new_values', to_jsonb(created))
  FROM created;

  -- At most 20 submitted routes. Resolve every route and shared physical slot
  -- once, and write endpoint sets in batches. Do not change unsubmitted routes.
  WITH submitted AS (
    SELECT value, value->>'physical_slot' AS slot,
      lower(btrim(value->>'purpose')) AS purpose,
      CASE WHEN value->>'purpose' = 'floor' THEN upper(btrim(value->>'floor_label')) ELSE '' END AS floor_key
    FROM jsonb_array_elements(p_destinations)
  ), matches AS (
    SELECT DISTINCT ON (s.purpose, s.floor_key) s.*,
      d.id, d.physical_printer_id
    FROM submitted s LEFT JOIN public.printer_destinations d ON d.restaurant_id = p_store_id
      AND lower(btrim(d.purpose)) = s.purpose
      AND COALESCE(upper(btrim(d.floor_label)), '') = s.floor_key
    ORDER BY s.purpose, s.floor_key, d.is_active DESC, d.created_at, d.id
  ), candidates AS (
    SELECT slot, (min(physical_printer_id::text))::uuid AS printer_id
    FROM matches GROUP BY slot
  ), shared_elsewhere AS (
    SELECT DISTINCT c.slot FROM candidates c
    JOIN public.printer_destinations d ON d.physical_printer_id = c.printer_id
    LEFT JOIN matches m ON m.id = d.id AND m.slot = c.slot
    WHERE m.id IS NULL
  ), slots AS (
    SELECT c.slot, CASE WHEN c.printer_id IS NULL OR e.slot IS NOT NULL
      THEN gen_random_uuid() ELSE c.printer_id END AS printer_id
    FROM candidates c LEFT JOIN shared_elsewhere e USING (slot)
  )
  SELECT jsonb_agg(m.value || jsonb_build_object('id', COALESCE(m.id, gen_random_uuid()),
    'physical_printer_id', s.printer_id, 'floor_key', m.floor_key))
  INTO v_routes FROM matches m JOIN slots s USING (slot);

  INSERT INTO public.physical_printers(id, restaurant_id, name, is_active)
  SELECT DISTINCT (value->>'physical_printer_id')::uuid, p_store_id,
    COALESCE(NULLIF(btrim(value->>'physical_name'), ''), btrim(value->>'name')), true
  FROM jsonb_array_elements(v_routes)
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, is_active = true, updated_at = now()
  WHERE physical_printers.name IS DISTINCT FROM EXCLUDED.name OR NOT physical_printers.is_active;

  WITH desired AS (
    SELECT (value->>'id')::uuid AS id, btrim(value->>'name') AS name,
      CASE WHEN value->>'connection' = 'usb' THEN '127.0.0.1' ELSE btrim(value->>'ip') END AS ip,
      CASE WHEN value->>'connection' = 'usb' THEN 9100 ELSE (value->>'port')::int END AS port,
      value->>'purpose' AS purpose, NULLIF(value->>'floor_key', '') AS floor_label,
      (value->>'physical_printer_id')::uuid AS physical_printer_id
    FROM jsonb_array_elements(v_routes)
  )
  INSERT INTO public.printer_destinations(id, restaurant_id, name, ip, port,
    purpose, floor_label, is_active, physical_printer_id)
  SELECT s.id, p_store_id, s.name, s.ip, s.port, s.purpose, s.floor_label, true, s.physical_printer_id
  FROM desired s LEFT JOIN public.printer_destinations d ON d.id = s.id WHERE d.id IS NULL;

  WITH desired AS (
    SELECT (value->>'id')::uuid AS id, btrim(value->>'name') AS name,
      CASE WHEN value->>'connection' = 'usb' THEN '127.0.0.1' ELSE btrim(value->>'ip') END AS ip,
      CASE WHEN value->>'connection' = 'usb' THEN 9100 ELSE (value->>'port')::int END AS port,
      NULLIF(value->>'floor_key', '') AS floor_label,
      (value->>'physical_printer_id')::uuid AS physical_printer_id
    FROM jsonb_array_elements(v_routes)
  )
  UPDATE public.printer_destinations d SET name = s.name, ip = s.ip, port = s.port,
    floor_label = s.floor_label, is_active = true,
    physical_printer_id = s.physical_printer_id, updated_at = now()
  FROM desired s WHERE d.id = s.id AND (d.name, d.ip, d.port, d.is_active, d.physical_printer_id)
    IS DISTINCT FROM (s.name, s.ip, s.port, true, s.physical_printer_id);

  -- Legacy row triggers name printers after their routes; restore physical names
  -- after that compatibility synchronization so reopening setup retains names.
  WITH desired AS (
    SELECT DISTINCT (value->>'physical_printer_id')::uuid AS id,
      COALESCE(NULLIF(btrim(value->>'physical_name'), ''), btrim(value->>'name')) AS name
    FROM jsonb_array_elements(v_routes)
  )
  UPDATE public.physical_printers p SET name = d.name, updated_at = now()
  FROM desired d WHERE p.id = d.id AND p.name IS DISTINCT FROM d.name;

  -- Invalidate prior test evidence when only the USB name or connection changes.
  WITH desired AS (
    SELECT DISTINCT (value->>'physical_printer_id')::uuid AS printer_id,
      value->>'connection' AS type,
      CASE WHEN value->>'connection' = 'usb' THEN NULL ELSE btrim(value->>'ip') END AS ip,
      CASE WHEN value->>'connection' = 'usb' THEN btrim(value->>'usb_printer_name') ELSE NULL END AS device_name,
      CASE WHEN value->>'connection' = 'usb' THEN 9100 ELSE (value->>'port')::int END AS port
    FROM jsonb_array_elements(v_routes)
  ), changed AS (
    SELECT d.printer_id FROM desired d LEFT JOIN public.printer_endpoints e
      ON e.physical_printer_id = d.printer_id AND e.is_active
    GROUP BY d.printer_id, d.type, d.ip, d.device_name, d.port
    HAVING count(e.id) <> 1 OR NOT bool_and((e.endpoint_type, e.ip, e.device_name, e.port)
      IS NOT DISTINCT FROM (d.type, d.ip, d.device_name, d.port))
  )
  UPDATE public.printer_destinations d SET updated_at = now()
  FROM changed c WHERE d.physical_printer_id = c.printer_id;

  UPDATE public.printer_endpoints e SET is_active = false, updated_at = now()
  WHERE e.is_active AND e.physical_printer_id IN (
    SELECT (value->>'physical_printer_id')::uuid FROM jsonb_array_elements(v_routes))
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_routes) s(value)
      WHERE (s.value->>'physical_printer_id')::uuid = e.physical_printer_id
        AND e.endpoint_type = s.value->>'connection'
        AND CASE WHEN e.endpoint_type = 'usb'
          THEN e.device_name = btrim(s.value->>'usb_printer_name')
          ELSE e.ip = btrim(s.value->>'ip') AND e.port = (s.value->>'port')::int END);

  INSERT INTO public.printer_endpoints(physical_printer_id, endpoint_type, device_name, port, priority, is_active)
  SELECT DISTINCT (value->>'physical_printer_id')::uuid, 'usb', btrim(value->>'usb_printer_name'), 9100, 5, true
  FROM jsonb_array_elements(v_routes) WHERE value->>'connection' = 'usb'
  ON CONFLICT (physical_printer_id, device_name) WHERE endpoint_type = 'usb'
  DO UPDATE SET is_active = true, priority = 5, updated_at = now()
  WHERE NOT printer_endpoints.is_active OR printer_endpoints.priority <> 5;

  INSERT INTO public.printer_endpoints(physical_printer_id, endpoint_type, ip, port, priority, is_active)
  SELECT DISTINCT (value->>'physical_printer_id')::uuid, value->>'connection', btrim(value->>'ip'),
    (value->>'port')::int, CASE WHEN value->>'connection' = 'wired' THEN 10 ELSE 20 END, true
  FROM jsonb_array_elements(v_routes) WHERE value->>'connection' <> 'usb'
  ON CONFLICT (physical_printer_id, endpoint_type, ip, port) WHERE endpoint_type IN ('wired', 'wireless')
  DO UPDATE SET is_active = true, priority = EXCLUDED.priority, updated_at = now()
  WHERE NOT printer_endpoints.is_active OR printer_endpoints.priority <> EXCLUDED.priority;

  v_previous_mode := public.get_store_fulfillment_mode(p_store_id);
  IF v_previous_mode IS DISTINCT FROM p_mode THEN
    -- Preserve the owner-only audit and paperless session/draining semantics.
    PERFORM public.super_admin_set_fulfillment_mode(p_store_id, p_mode,
      'Store opening printer operation setup', gen_random_uuid());
  END IF;
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'admin_apply_store_opening_config_v2', 'restaurants', p_store_id,
    jsonb_build_object('mode', p_mode, 'previous_mode', v_previous_mode,
      'summary_counts', v_validation->'plan', 'submitted_table_count', jsonb_array_length(p_tables),
      'submitted_destination_count', jsonb_array_length(p_destinations)));
  RETURN jsonb_build_object('store_id', p_store_id, 'mode', p_mode, 'plan', v_validation->'plan');
END;
$$;

REVOKE ALL ON FUNCTION public.admin_validate_store_opening_config_v2(uuid,jsonb,jsonb,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_apply_store_opening_config_v2(uuid,jsonb,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_validate_store_opening_config_v2(uuid,jsonb,jsonb,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_store_opening_config_v2(uuid,jsonb,jsonb,text) TO authenticated, service_role;

DO $$
BEGIN
  IF to_regprocedure('public.admin_apply_store_opening_config_v2(uuid,jsonb,jsonb,text)') IS NULL
    OR pg_get_functiondef('public.admin_get_store_opening_readiness(uuid)'::regprocedure) NOT LIKE '%v_mode = ''pos_print''%'
    OR has_function_privilege('anon', 'public.admin_apply_store_opening_config_v2(uuid,jsonb,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'STORE_OPENING_PRINTER_MODES_VERIFICATION_FAILED';
  END IF;
END;
$$;
COMMIT;
