-- Executable Store Opening Setup Wizard database contract.
-- Run against a fully migrated disposable database with:
--   psql -X -v ON_ERROR_STOP=1 --single-transaction "$DB_URL" \
--     --file supabase/tests/store_opening_setup_contract_test.sql

BEGIN;

CREATE TEMP TABLE _store_setup_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text NOT NULL
);

DO $contract$
DECLARE
  v_auth uuid := '57000000-0000-4000-8000-000000000001';
  v_waiter_auth uuid := '57000000-0000-4000-8000-000000000002';
  v_store uuid := '57000000-0000-4000-8000-000000000010';
  v_other_store uuid := '57000000-0000-4000-8000-000000000020';
  v_brand uuid := '57000000-0000-4000-8000-000000000030';
  v_tax uuid := '57000000-0000-4000-8000-000000000040';
  v_company uuid := '57000000-0000-4000-8000-000000000050';
  v_brand_master uuid := '57000000-0000-4000-8000-000000000060';
  v_tables jsonb := '[
    {"table_number":"101","seat_count":4,"floor_label":"1F"},
    {"table_number":"201","seat_count":4,"floor_label":"2F"},
    {"table_number":"301","seat_count":6,"floor_label":"3F"}
  ]'::jsonb;
  v_destinations jsonb := '[
    {"name":"Cashier Receipt","ip":"192.168.50.10","port":9100,"purpose":"receipt","floor_label":null},
    {"name":"Kitchen","ip":"192.168.50.11","port":9100,"purpose":"kitchen","floor_label":null},
    {"name":"1F via Cashier","ip":"192.168.50.10","port":9100,"purpose":"floor","floor_label":"1F"},
    {"name":"2F","ip":"192.168.50.12","port":9100,"purpose":"floor","floor_label":"2F"},
    {"name":"3F","ip":"192.168.50.13","port":9100,"purpose":"floor","floor_label":"3F"}
  ]'::jsonb;
  v_result jsonb;
  v_before_tables int;
  v_before_destinations int;
  v_after_tables int;
  v_after_destinations int;
  v_blocked boolean;
  v_destination record;
  v_job public.print_jobs%ROWTYPE;
BEGIN
  INSERT INTO auth.users (id, email)
  VALUES
    (v_auth, 'store.setup.admin@globos.test'),
    (v_waiter_auth, 'store.setup.waiter@globos.test');

  INSERT INTO public.tax_entity (
    id, tax_code, name, owner_type, einvoice_provider, data_source
  ) VALUES (
    v_tax, 'STORE_SETUP_CONTRACT', 'Store Setup Contract Entity',
    'internal', 'meinvoice', 'VNPT_EPAY'
  );
  INSERT INTO public.companies (id, name)
  VALUES (v_company, 'Store Setup Contract Company');
  INSERT INTO public.brand_master (id, company_id, name, type)
  VALUES (
    v_brand_master, v_company, 'Store Setup Contract Master', 'internal'
  );
  INSERT INTO public.brands (
    id, company_id, code, name, brand_master_id, suggested_tax_entity_id
  ) VALUES (
    v_brand, v_company, 'store_setup_contract',
    'Store Setup Contract Brand', v_brand_master, v_tax
  );
  INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
  VALUES (v_tax, v_brand);
  INSERT INTO public.restaurants (
    id, name, operation_mode, is_active, brand_id, tax_entity_id
  ) VALUES
    (v_store, 'Store Setup Contract', 'standard', true, v_brand, v_tax),
    (v_other_store, 'Other Store Setup Contract', 'standard', true, v_brand, v_tax);
  INSERT INTO public.users (
    auth_id, restaurant_id, role, full_name, is_active
  ) VALUES
    (v_auth, v_store, 'admin', 'Store Setup Admin', true),
    (v_waiter_auth, v_store, 'waiter', 'Store Setup Waiter', true);
  INSERT INTO public.user_store_access (
    user_id, store_id, is_primary, is_active, source_type
  )
  SELECT id, v_store, true, true, 'direct'
  FROM public.users WHERE auth_id IN (v_auth, v_waiter_auth);

  INSERT INTO public.tables (
    restaurant_id, table_number, seat_count, status, floor_label
  ) VALUES (v_store, 'LEGACY', 2, 'available', '1F');
  INSERT INTO public.printer_destinations (
    restaurant_id, name, ip, port, purpose, is_active
  ) VALUES (v_store, 'Legacy Tray', '192.168.50.20', 9100, 'tray', true);

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_waiter_auth, 'role', 'authenticated')::text,
    true
  );
  v_blocked := false;
  BEGIN
    PERFORM public.admin_validate_store_opening_config(
      v_store, v_tables, v_destinations
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%ADMIN_MUTATION_FORBIDDEN%';
  END;
  INSERT INTO _store_setup_results VALUES (
    'unauthorized role rejected', v_blocked, 'waiter cannot validate'
  );

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  v_blocked := false;
  BEGIN
    PERFORM public.admin_validate_store_opening_config(
      v_other_store, v_tables, v_destinations
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%ADMIN_MUTATION_FORBIDDEN%';
  END;
  INSERT INTO _store_setup_results VALUES (
    'tenant boundary rejected', v_blocked, 'store admin cannot cross store'
  );

  v_result := public.admin_validate_store_opening_config(
    v_store, v_tables, v_destinations
  );
  INSERT INTO _store_setup_results VALUES (
    'valid template preview', (v_result->>'valid')::boolean,
    v_result::text
  );

  v_result := public.admin_apply_store_opening_config(
    v_store, v_tables, v_destinations
  );
  INSERT INTO _store_setup_results VALUES (
    'five logical routes persisted',
    (SELECT count(*) = 5 FROM public.printer_destinations
      WHERE restaurant_id = v_store AND purpose <> 'tray' AND is_active),
    'receipt,kitchen,1F,2F,3F'
  );
  INSERT INTO _store_setup_results VALUES (
    'cashier receipt and 1F share physical printer',
    (SELECT count(DISTINCT ip) = 1 FROM public.printer_destinations
      WHERE restaurant_id = v_store AND is_active
        AND (purpose = 'receipt' OR (purpose = 'floor' AND floor_label = '1F'))),
    'same private LAN IP is permitted across route keys'
  );
  INSERT INTO _store_setup_results VALUES (
    'unspecified rows preserved',
    EXISTS (SELECT 1 FROM public.tables
      WHERE restaurant_id = v_store AND table_number = 'LEGACY')
      AND EXISTS (SELECT 1 FROM public.printer_destinations
        WHERE restaurant_id = v_store AND purpose = 'tray' AND is_active),
    'no implicit delete or deactivation'
  );
  INSERT INTO _store_setup_results VALUES (
    'summary audit recorded',
    EXISTS (SELECT 1 FROM public.audit_logs
      WHERE action = 'admin_apply_store_opening_config'
        AND entity_id = v_store
        AND details->>'store_id' = v_store::text
        AND details ? 'summary_counts'),
    'store id and counts are auditable'
  );

  SELECT count(*) INTO v_before_tables
  FROM public.tables WHERE restaurant_id = v_store;
  SELECT count(*) INTO v_before_destinations
  FROM public.printer_destinations WHERE restaurant_id = v_store;
  PERFORM public.admin_apply_store_opening_config(
    v_store, v_tables, v_destinations
  );
  SELECT count(*) INTO v_after_tables
  FROM public.tables WHERE restaurant_id = v_store;
  SELECT count(*) INTO v_after_destinations
  FROM public.printer_destinations WHERE restaurant_id = v_store;
  INSERT INTO _store_setup_results VALUES (
    'identical apply is idempotent',
    v_before_tables = v_after_tables
      AND v_before_destinations = v_after_destinations,
    format('tables %s/%s routes %s/%s', v_before_tables, v_after_tables,
      v_before_destinations, v_after_destinations)
  );

  UPDATE public.tables SET status = 'occupied'
  WHERE restaurant_id = v_store AND table_number = '201';
  v_blocked := false;
  BEGIN
    PERFORM public.admin_apply_store_opening_config(
      v_store,
      jsonb_set(v_tables, '{1,floor_label}', '"3F"'::jsonb),
      v_destinations
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%STORE_SETUP_CONFIG_INVALID%';
  END;
  INSERT INTO _store_setup_results VALUES (
    'occupied table change rolls back atomically',
    v_blocked AND (SELECT floor_label = '2F' FROM public.tables
      WHERE restaurant_id = v_store AND table_number = '201'),
    'occupied floor remains unchanged'
  );
  UPDATE public.tables SET status = 'available'
  WHERE restaurant_id = v_store AND table_number = '201';

  SELECT count(*) INTO v_before_tables
  FROM public.tables WHERE restaurant_id = v_store;
  v_result := public.admin_validate_store_opening_config(
    v_store,
    v_tables || '[{"table_number":"BAD","seat_count":0,"floor_label":""}]'::jsonb,
    v_destinations
  );
  v_blocked := false;
  BEGIN
    PERFORM public.admin_apply_store_opening_config(
      v_store,
      v_tables || '[{"table_number":"BAD","seat_count":0,"floor_label":""}]'::jsonb,
      v_destinations
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%STORE_SETUP_CONFIG_INVALID%';
  END;
  INSERT INTO _store_setup_results VALUES (
    'invalid row blocks all writes',
    NOT (v_result->>'valid')::boolean AND v_blocked
      AND v_before_tables = (SELECT count(*) FROM public.tables
        WHERE restaurant_id = v_store),
    (v_result->'errors')::text
  );

  v_blocked := false;
  BEGIN
    INSERT INTO public.printer_destinations (
      restaurant_id, name, ip, port, purpose, is_active
    ) VALUES (v_store, 'Duplicate Receipt', '192.168.50.99', 9100,
      'receipt', true);
  EXCEPTION WHEN unique_violation THEN
    v_blocked := true;
  END;
  INSERT INTO _store_setup_results VALUES (
    'duplicate active route constrained', v_blocked,
    'partial unique route index rejected duplicate'
  );

  v_result := public.admin_get_store_opening_readiness(v_store);
  INSERT INTO _store_setup_results VALUES (
    'readiness requires destination tests',
    NOT (v_result->>'ready')::boolean,
    v_result::text
  );
  FOR v_destination IN
    SELECT d.* FROM public.printer_destinations d
    WHERE d.restaurant_id = v_store AND d.is_active
      AND d.purpose IN ('receipt', 'kitchen', 'floor')
  LOOP
    v_job := public.admin_enqueue_printer_test_job(v_store, v_destination.id);
    UPDATE public.print_jobs SET status = 'done', updated_at = now()
    WHERE id = v_job.id;
  END LOOP;
  v_result := public.admin_get_store_opening_readiness(v_store);
  INSERT INTO _store_setup_results VALUES (
    'readiness derives successful recent tests',
    (v_result->>'ready')::boolean,
    v_result::text
  );

  INSERT INTO _store_setup_results VALUES (
    'order and payment contracts do not call readiness',
    position('store_opening_readiness' in lower(
      pg_get_functiondef('public.create_order(uuid,uuid,jsonb)'::regprocedure)
    )) = 0
    AND position('store_opening_readiness' in lower(
      pg_get_functiondef((SELECT oid::regprocedure FROM pg_proc
        WHERE proname = 'process_payment' ORDER BY oid DESC LIMIT 1))
    )) = 0,
    'readiness remains informational'
  );
END;
$contract$;

DO $report$
DECLARE
  v_failures int;
  v_report text;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok),
    string_agg((CASE WHEN ok THEN 'OK ' ELSE 'FAIL ' END) || scenario ||
      CASE WHEN ok THEN '' ELSE ' :: ' || detail END, ' | ' ORDER BY scenario)
  INTO v_failures, v_report
  FROM _store_setup_results;
  IF v_failures > 0 THEN
    RAISE EXCEPTION 'STORE_OPENING_SETUP_CONTRACT failures=% >>> %',
      v_failures, v_report;
  END IF;
  RAISE NOTICE 'STORE_OPENING_SETUP_CONTRACT scenarios=% >>> %',
    (SELECT count(*) FROM _store_setup_results), v_report;
END;
$report$;

ROLLBACK;
