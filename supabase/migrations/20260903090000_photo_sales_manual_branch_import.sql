-- production-gate: self-verifying
BEGIN;

CREATE OR REPLACE FUNCTION public.import_photo_objet_sales_excel(
  p_sale_date date,
  p_source_file_name text,
  p_rows jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_now timestamptz := statement_timestamp();
  v_hcm_today date := (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_interval_start timestamptz;
  v_interval_end timestamptz;
  v_item jsonb;
  v_source_row integer;
  v_branch_code text;
  v_source_store_name text;
  v_device_name text;
  v_device_id text;
  v_sale_time_text text;
  v_sale_time time;
  v_sold_at timestamptz;
  v_amount bigint;
  v_raw_type text;
  v_occurrence_no integer;
  v_store_id uuid;
  v_store_name text;
  v_pull_run_id uuid;
  v_existing_raw_id uuid;
  v_source_hash text;
  v_run_ids jsonb := '{}'::jsonb;
  v_inserted_rows integer := 0;
  v_duplicate_rows integer := 0;
  v_rows_read integer;
  v_aggregate_rows integer;
  v_branches jsonb;
  v_total_amount bigint;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_FORBIDDEN';
  END IF;
  IF p_sale_date IS NULL OR p_sale_date < DATE '2020-01-01'
     OR p_sale_date > v_hcm_today THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_DATE_INVALID';
  END IF;
  IF p_source_file_name IS NULL
     OR length(btrim(p_source_file_name)) NOT BETWEEN 1 AND 255 THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_FILE_NAME_INVALID';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 10000 THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_ROWS_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('photo-sales-manual:' || p_sale_date::text, 0)
  );
  v_interval_start := p_sale_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_interval_end := (p_sale_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_ROW_INVALID';
    END IF;
    IF coalesce(v_item->>'source_row', '') !~ '^[1-9][0-9]*$'
       OR length(v_item->>'source_row') > 7 THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_SOURCE_ROW_INVALID';
    END IF;
    v_source_row := (v_item->>'source_row')::integer;
    v_branch_code := upper(btrim(coalesce(v_item->>'branch_code', '')));
    IF v_branch_code NOT IN ('BH', 'DA', 'LT', 'TD', 'QT', 'NZ') THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_BRANCH_INVALID:%', v_branch_code;
    END IF;

    v_source_store_name := btrim(coalesce(v_item->>'store_name', ''));
    v_device_name := btrim(coalesce(v_item->>'device_name', ''));
    v_device_id := nullif(btrim(coalesce(v_item->>'device_id', '')), '');
    v_sale_time_text := btrim(coalesce(v_item->>'sale_time', ''));
    v_raw_type := nullif(btrim(coalesce(v_item->>'raw_type', '')), '');
    IF length(v_source_store_name) > 300
       OR length(v_device_name) NOT BETWEEN 1 AND 300
       OR length(coalesce(v_device_id, '')) > 200
       OR length(coalesce(v_raw_type, '')) > 100 THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_TEXT_INVALID:%', v_source_row;
    END IF;
    IF v_sale_time_text !~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_TIME_INVALID:%', v_source_row;
    END IF;
    v_sale_time := v_sale_time_text::time;
    v_sold_at := (p_sale_date::timestamp + v_sale_time)
      AT TIME ZONE 'Asia/Ho_Chi_Minh';

    IF coalesce(v_item->>'amount', '') !~ '^[1-9][0-9]*$'
       OR length(v_item->>'amount') > 18 THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_AMOUNT_INVALID:%', v_source_row;
    END IF;
    v_amount := (v_item->>'amount')::bigint;
    IF coalesce(v_item->>'occurrence_no', '') !~ '^[1-9][0-9]*$'
       OR length(v_item->>'occurrence_no') > 7 THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_OCCURRENCE_INVALID:%', v_source_row;
    END IF;
    v_occurrence_no := (v_item->>'occurrence_no')::integer;

    SELECT store.id, store.name
    INTO v_store_id, v_store_name
    FROM public.restaurants store
    WHERE store.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND upper(btrim(store.short_code)) = v_branch_code
      AND store.is_active = true
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PHOTO_SALES_IMPORT_BRANCH_STORE_NOT_FOUND:%', v_branch_code;
    END IF;

    IF NOT (v_run_ids ? v_branch_code) THEN
      INSERT INTO public.photo_objet_sales_pull_runs (
        store_id,
        target_date,
        collector_method,
        run_source,
        slot_id,
        slot_date_hcm,
        slot_time_hcm,
        interval_start_at,
        interval_end_at,
        status,
        rows_read,
        rows_inserted,
        rows_duplicate,
        aggregate_rows,
        interval_rows,
        started_at
      ) VALUES (
        v_store_id,
        p_sale_date,
        'excel',
        'manual',
        NULL,
        p_sale_date,
        NULL,
        v_interval_start,
        v_interval_end,
        'started',
        0,
        0,
        0,
        0,
        0,
        v_now
      )
      RETURNING id INTO v_pull_run_id;
      v_run_ids := v_run_ids || jsonb_build_object(
        v_branch_code,
        v_pull_run_id::text
      );
    ELSE
      v_pull_run_id := (v_run_ids->>v_branch_code)::uuid;
    END IF;

    SELECT raw.id
    INTO v_existing_raw_id
    FROM public.photo_objet_sales_raw raw
    WHERE raw.store_id = v_store_id
      AND raw.sale_date = p_sale_date
      AND raw.source_identity_version = 2
      AND raw.occurrence_no = v_occurrence_no
      AND raw.device_name = v_device_name
      AND coalesce(raw.device_id, '') = coalesce(v_device_id, '')
      AND raw.sold_at = v_sold_at
      AND raw.amount = v_amount
      AND coalesce(raw.raw_type, '') = coalesce(v_raw_type, '')
    LIMIT 1;

    IF FOUND THEN
      v_duplicate_rows := v_duplicate_rows + 1;
      CONTINUE;
    END IF;

    -- Keep the retired collector's v2 stable-JSON hash contract. This makes
    -- a future emergency rollback of that collector recognize manually
    -- imported rows instead of inserting the same source sale again.
    v_source_hash := encode(
      extensions.digest(
        convert_to(
          concat(
            '{"amount":', v_amount::text,
            ',"device_id":', to_jsonb(coalesce(v_device_id, ''))::text,
            ',"device_name":', to_jsonb(v_device_name)::text,
            ',"occurrence_no":', v_occurrence_no::text,
            ',"raw_type":', to_jsonb(coalesce(v_raw_type, ''))::text,
            ',"sale_date":', to_jsonb(p_sale_date::text)::text,
            ',"sold_at":',
              to_jsonb(
                p_sale_date::text || 'T' || v_sale_time_text || '+07:00'
              )::text,
            ',"source_identity_version":2',
            ',"store_id":', to_jsonb(v_store_id::text)::text,
            '}'
          ),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );

    INSERT INTO public.photo_objet_sales_raw (
      store_id,
      sale_date,
      device_name,
      device_id,
      sale_time_text,
      sold_at,
      amount,
      raw_type,
      payment_method,
      buyer_kind,
      raw_payload,
      source_hash,
      source_identity_version,
      occurrence_no,
      interval_start_at,
      interval_end_at,
      pull_run_id,
      invoice_enqueue_status,
      invoice_enqueue_error,
      first_seen_at,
      last_seen_at,
      created_at,
      updated_at
    ) VALUES (
      v_store_id,
      p_sale_date,
      v_device_name,
      v_device_id,
      v_sale_time_text,
      v_sold_at,
      v_amount,
      v_raw_type,
      'CASH',
      'anonymous',
      jsonb_build_object(
        'source', 'moers_manual_excel',
        'source_file_name', btrim(p_source_file_name),
        'source_row', v_source_row,
        'branch_code', v_branch_code,
        'store_name', v_source_store_name,
        'row', jsonb_build_object(
          'Branch', v_branch_code,
          'Store', v_source_store_name,
          'Device Name', v_device_name,
          'Device ID', coalesce(v_device_id, ''),
          'Time', v_sale_time_text,
          'Amount', v_amount,
          'Type', coalesce(v_raw_type, '')
        )
      ),
      v_source_hash,
      2,
      v_occurrence_no,
      v_interval_start,
      v_interval_end,
      v_pull_run_id,
      'skipped',
      'MANUAL_MISA_EXCEL_EXPORT',
      v_now,
      v_now,
      v_now,
      v_now
    );
    v_inserted_rows := v_inserted_rows + 1;
  END LOOP;

  IF EXISTS (
    WITH identities AS (
      SELECT
        item->>'branch_code' AS branch_code,
        coalesce(item->>'device_id', '') AS device_id,
        item->>'device_name' AS device_name,
        item->>'sale_time' AS sale_time,
        item->>'amount' AS amount,
        coalesce(item->>'raw_type', '') AS raw_type,
        (item->>'occurrence_no')::integer AS occurrence_no
      FROM jsonb_array_elements(p_rows) item
    )
    SELECT 1
    FROM identities
    GROUP BY branch_code, device_id, device_name, sale_time, amount, raw_type
    HAVING min(occurrence_no) <> 1
       OR max(occurrence_no) <> count(*)
       OR count(DISTINCT occurrence_no) <> count(*)
  ) THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_OCCURRENCE_SEQUENCE_INVALID';
  END IF;

  FOR v_branch_code, v_pull_run_id IN
    SELECT entry.key, entry.value::uuid
    FROM jsonb_each_text(v_run_ids) entry
  LOOP
    SELECT store.id, store.name
    INTO STRICT v_store_id, v_store_name
    FROM public.restaurants store
    WHERE store.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND upper(btrim(store.short_code)) = v_branch_code
      AND store.is_active = true;

    INSERT INTO public.photo_objet_sales (
      store_id,
      sale_date,
      device_name,
      device_id,
      gross_sales,
      service_amount,
      transaction_count,
      service_count,
      raw_rows,
      pulled_at,
      pull_source
    )
    SELECT
      v_store_id,
      p_sale_date,
      raw.device_name,
      min(raw.device_id) FILTER (WHERE raw.device_id IS NOT NULL),
      sum(raw.amount) FILTER (WHERE raw.amount > 0)::bigint,
      coalesce(sum(raw.amount) FILTER (
        WHERE raw.amount > 0
          AND regexp_replace(
            lower(btrim(coalesce(raw.raw_type, ''))),
            '[^a-z0-9]+',
            ' ',
            'g'
          ) ~ '(^| )(service|coin)( |$)'
      ), 0)::bigint,
      count(*) FILTER (WHERE raw.amount > 0)::integer,
      count(*) FILTER (
        WHERE raw.amount > 0
          AND regexp_replace(
            lower(btrim(coalesce(raw.raw_type, ''))),
            '[^a-z0-9]+',
            ' ',
            'g'
          ) ~ '(^| )(service|coin)( |$)'
      )::integer,
      jsonb_agg(raw.raw_payload->'row' ORDER BY raw.sold_at, raw.id)
        FILTER (WHERE raw.amount > 0),
      v_now,
      'manual'
    FROM public.photo_objet_sales_raw raw
    WHERE raw.store_id = v_store_id
      AND raw.sale_date = p_sale_date
    GROUP BY raw.device_name
    HAVING count(*) FILTER (WHERE raw.amount > 0) > 0
    ON CONFLICT (store_id, sale_date, device_name) DO UPDATE
    SET device_id = EXCLUDED.device_id,
        gross_sales = EXCLUDED.gross_sales,
        service_amount = EXCLUDED.service_amount,
        transaction_count = EXCLUDED.transaction_count,
        service_count = EXCLUDED.service_count,
        raw_rows = EXCLUDED.raw_rows,
        pulled_at = EXCLUDED.pulled_at,
        pull_source = 'manual';

    SELECT count(*)::integer
    INTO v_rows_read
    FROM jsonb_array_elements(p_rows) item
    WHERE item->>'branch_code' = v_branch_code;

    SELECT count(*)::integer
    INTO v_aggregate_rows
    FROM public.photo_objet_sales sales
    WHERE sales.store_id = v_store_id
      AND sales.sale_date = p_sale_date;

    UPDATE public.photo_objet_sales_pull_runs run
    SET status = 'success',
        rows_read = v_rows_read,
        rows_inserted = (
          SELECT count(*)::integer
          FROM public.photo_objet_sales_raw raw
          WHERE raw.pull_run_id = v_pull_run_id
        ),
        rows_duplicate = v_rows_read - (
          SELECT count(*)::integer
          FROM public.photo_objet_sales_raw raw
          WHERE raw.pull_run_id = v_pull_run_id
        ),
        aggregate_rows = v_aggregate_rows,
        interval_rows = v_rows_read,
        finished_at = statement_timestamp(),
        error_message = NULL
    WHERE run.id = v_pull_run_id;
  END LOOP;

  SELECT coalesce(sum((item->>'amount')::bigint), 0)::bigint
  INTO v_total_amount
  FROM jsonb_array_elements(p_rows) item;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'branch_code', branch.branch_code,
        'store_id', store.id,
        'store_name', store.name,
        'receipt_count', branch.receipt_count,
        'total_amount', branch.total_amount
      )
      ORDER BY store.name
    ),
    '[]'::jsonb
  )
  INTO v_branches
  FROM (
    SELECT
      item->>'branch_code' AS branch_code,
      count(*)::integer AS receipt_count,
      sum((item->>'amount')::bigint)::bigint AS total_amount
    FROM jsonb_array_elements(p_rows) item
    GROUP BY item->>'branch_code'
  ) branch
  JOIN public.restaurants store
    ON store.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
   AND upper(btrim(store.short_code)) = branch.branch_code
   AND store.is_active = true;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    v_actor_id,
    'import_photo_objet_sales_excel',
    'photo_objet_sales_pull_runs',
    NULL,
    jsonb_build_object(
      'sale_date', p_sale_date,
      'source_file_name', btrim(p_source_file_name),
      'source_rows', jsonb_array_length(p_rows),
      'inserted_rows', v_inserted_rows,
      'duplicate_rows', v_duplicate_rows,
      'total_amount', v_total_amount,
      'branches', v_branches
    )
  );

  RETURN jsonb_build_object(
    'sale_date', p_sale_date,
    'source_rows', jsonb_array_length(p_rows),
    'inserted_rows', v_inserted_rows,
    'duplicate_rows', v_duplicate_rows,
    'total_amount', v_total_amount,
    'branches', v_branches
  );
END;
$$;

REVOKE ALL ON FUNCTION public.import_photo_objet_sales_excel(
  date,
  text,
  jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_photo_objet_sales_excel(
  date,
  text,
  jsonb
) TO authenticated, service_role;

COMMENT ON FUNCTION public.import_photo_objet_sales_excel(date, text, jsonb) IS
  'Atomically imports a validated Moers workbook into each Photo Objet POS store by canonical Branch code. Replays are idempotent by immutable sale identity and occurrence number.';

CREATE OR REPLACE FUNCTION public.get_photo_sales_misa_exports_by_tax_entity(
  p_business_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_business_date date := p_business_date;
  v_hcm_today date := (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_entities jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_FORBIDDEN';
  END IF;
  IF v_business_date IS NULL
     OR v_business_date < DATE '2020-01-01'
     OR v_business_date > v_hcm_today THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_DATE_INVALID';
  END IF;

  WITH photo_rows AS (
    SELECT
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      raw.source_hash,
      raw.store_id,
      store.name AS store_name,
      raw.device_name,
      raw.sold_at,
      raw.amount
    FROM public.photo_objet_sales_raw raw
    JOIN public.restaurants store
      ON store.id = raw.store_id
     AND store.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    JOIN public.tax_entity seller
      ON seller.id = coalesce(
        (
          SELECT history.tax_entity_id
          FROM public.store_tax_entity_history history
          WHERE history.store_id = raw.store_id
            AND history.effective_from <= raw.sold_at
            AND (
              history.effective_to IS NULL
              OR raw.sold_at < history.effective_to
            )
          ORDER BY history.effective_from DESC, history.created_at DESC
          LIMIT 1
        ),
        store.tax_entity_id
      )
    WHERE raw.sale_date = v_business_date
      AND raw.source_identity_version = 2
      AND raw.amount > 0
  ),
  entity_rollups AS (
    SELECT
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name,
      count(DISTINCT rows.store_id)::integer AS store_count,
      count(*)::integer AS receipt_count,
      sum(rows.amount)::bigint AS gross_sales,
      jsonb_agg(
        jsonb_build_object(
          'source_hash', rows.source_hash,
          'store_id', rows.store_id,
          'store_name', rows.store_name,
          'device_name', rows.device_name,
          'sold_at', rows.sold_at,
          'amount', rows.amount
        )
        ORDER BY rows.sold_at, rows.source_hash
      ) AS receipts
    FROM photo_rows rows
    GROUP BY
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tax_entity_id', rollup.tax_entity_id,
        'seller_tax_code', rollup.seller_tax_code,
        'seller_legal_name', rollup.seller_legal_name,
        'store_count', rollup.store_count,
        'receipt_count', rollup.receipt_count,
        'gross_sales', rollup.gross_sales,
        'receipts', rollup.receipts
      )
      ORDER BY rollup.seller_tax_code, rollup.tax_entity_id
    ),
    '[]'::jsonb
  )
  INTO v_entities
  FROM entity_rollups rollup;

  RETURN jsonb_build_object(
    'business_date', v_business_date,
    'entity_count', jsonb_array_length(v_entities),
    'entities', v_entities
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_photo_sales_misa_exports_by_tax_entity(date)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_photo_sales_misa_exports_by_tax_entity(date)
  TO authenticated;

COMMENT ON FUNCTION public.get_photo_sales_misa_exports_by_tax_entity(date) IS
  'Returns positive immutable Photo Objet receipts grouped by the seller legal entity effective when each sale occurred, for legal-entity-safe combined MISA export.';

DO $$
DECLARE
  v_definition text;
  v_export_definition text;
BEGIN
  IF to_regprocedure(
    'public.import_photo_objet_sales_excel(date,text,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_VERIFY_FUNCTION_MISSING';
  END IF;
  SELECT pg_get_functiondef(
    'public.import_photo_objet_sales_excel(date,text,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('PHOTO_SALES_IMPORT_FORBIDDEN' IN v_definition) = 0
     OR position('source_identity_version = 2' IN v_definition) = 0
     OR position('source_identity_version":2' IN v_definition) = 0
     OR position('ON CONFLICT (store_id, sale_date, device_name)' IN v_definition) = 0
     OR position('upper(btrim(store.short_code)) = v_branch_code' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PHOTO_SALES_IMPORT_VERIFY_CONTRACT_INVALID';
  END IF;
  IF to_regprocedure(
    'public.get_photo_sales_misa_exports_by_tax_entity(date)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_VERIFY_FUNCTION_MISSING';
  END IF;
  SELECT pg_get_functiondef(
    'public.get_photo_sales_misa_exports_by_tax_entity(date)'::regprocedure
  ) INTO v_export_definition;
  IF position('raw.source_identity_version = 2' IN v_export_definition) = 0
     OR position('history.effective_from <= raw.sold_at' IN v_export_definition) = 0
     OR position('raw.amount > 0' IN v_export_definition) = 0
     OR pg_catalog.has_function_privilege(
       'anon',
       'public.get_photo_sales_misa_exports_by_tax_entity(date)',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.get_photo_sales_misa_exports_by_tax_entity(date)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_VERIFY_CONTRACT_INVALID';
  END IF;
END;
$$;

COMMIT;
