-- meinvoice_multi_entity_contract_test.sql
-- Prod-safe rollback contract: one brand shared by two legal entities must
-- enqueue meInvoice jobs strictly by the selling store's tax_entity_id.
-- Verified against prod 2026-07-11 (6/6 PASS, exception-rollback run).
--
-- Run against a fully migrated database:
--   psql "$DB_URL" -f supabase/tests/meinvoice_multi_entity_contract_test.sql
--
-- Scenarios:
--   S1 same brand, two stores under different tax entities: each completed
--      revenue order enqueues exactly one meinvoice_jobs row snapshotting
--      that store's tax_entity_id and store_id (no cross-entity bleed).
--      Fixtures go through the hierarchy junction (tax_entity_brands) that
--      the composite FK restaurants(tax_entity_id, brand_id) enforces.
--   S2 re-completing the same order does not duplicate its queue row.
--   S3 staff-meal completion enqueues nothing.
--   S4 without vendor config the jobs stay in pending_manual_config.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _misa_results (
  scenario text,
  ok boolean,
  detail text
);

DO $test$
DECLARE
  v_company uuid := 'f2000000-0000-4000-8000-000000000000';
  v_master uuid := 'f2000000-0000-4000-8000-000000000001';
  v_brand uuid := 'f2000000-0000-4000-8000-000000000002';
  v_entity_a uuid := 'f2000000-0000-4000-8000-00000000000a';
  v_entity_b uuid := 'f2000000-0000-4000-8000-00000000000b';
  v_store_a uuid := 'f2000000-0000-4000-8000-0000000000a1';
  v_store_b uuid := 'f2000000-0000-4000-8000-0000000000b1';
  v_cat_a uuid := 'f2000000-0000-4000-8000-0000000000c1';
  v_cat_b uuid := 'f2000000-0000-4000-8000-0000000000c2';
  v_menu_a uuid := 'f2000000-0000-4000-8000-0000000000e1';
  v_menu_b uuid := 'f2000000-0000-4000-8000-0000000000e2';
  v_order_a uuid := 'f2000000-0000-4000-8000-0000000000d1';
  v_order_b uuid := 'f2000000-0000-4000-8000-0000000000d2';
  v_order_staff uuid := 'f2000000-0000-4000-8000-0000000000d3';
  v_job_a record;
  v_job_b record;
  v_count int;
BEGIN
  INSERT INTO public.companies (id, name)
  VALUES (v_company, 'MISA Test Company');

  INSERT INTO public.brand_master (id, company_id, name, type)
  VALUES (v_master, v_company, 'MISA Multi Entity Master', 'internal');

  INSERT INTO public.brands (id, brand_master_id, code, name)
  VALUES (v_brand, v_master, 'misa_multi_entity_test', 'MISA Multi Entity Brand');

  INSERT INTO public.tax_entity
    (id, tax_code, name, owner_type, einvoice_provider, data_source, onboarding_status)
  VALUES
    (v_entity_a, 'MISATEST0000001', 'Entity A Co., Ltd.', 'internal', 'meinvoice', 'manual', 'ready'),
    (v_entity_b, 'MISATEST0000002', 'Entity B Co., Ltd.', 'internal', 'meinvoice', 'manual', 'ready');

  -- One brand, two legal entities: the sanctioned hierarchy shape.
  INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
  VALUES (v_entity_a, v_brand), (v_entity_b, v_brand);

  INSERT INTO public.restaurants (id, name, address, is_active, brand_id, tax_entity_id)
  VALUES
    (v_store_a, 'Entity A Store', 'test', true, v_brand, v_entity_a),
    (v_store_b, 'Entity B Store', 'test', true, v_brand, v_entity_b);

  INSERT INTO public.menu_categories (id, restaurant_id, name, sort_order)
  VALUES
    (v_cat_a, v_store_a, 'MISA Test Cat', 999),
    (v_cat_b, v_store_b, 'MISA Test Cat', 999);

  INSERT INTO public.menu_items (id, restaurant_id, category_id, name, price, sort_order)
  VALUES
    (v_menu_a, v_store_a, v_cat_a, 'A dish', 110000, 999),
    (v_menu_b, v_store_b, v_cat_b, 'B dish', 55000, 999);

  -- S1 fixtures: one revenue order per store.
  INSERT INTO public.orders (id, restaurant_id, status)
  VALUES
    (v_order_a, v_store_a, 'serving'),
    (v_order_b, v_store_b, 'serving');

  INSERT INTO public.order_items
    (order_id, restaurant_id, menu_item_id, display_name, quantity, unit_price,
     status, vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax)
  VALUES
    (v_order_a, v_store_a, v_menu_a, 'A dish', 1, 110000, 'served', 10, 10000, 100000, 110000),
    (v_order_b, v_store_b, v_menu_b, 'B dish', 1, 55000, 'served', 10, 5000, 50000, 55000);

  INSERT INTO public.payments
    (order_id, restaurant_id, method, amount, amount_portion, is_revenue)
  VALUES
    (v_order_a, v_store_a, 'CASH', 110000, 110000, true),
    (v_order_b, v_store_b, 'CASH', 55000, 55000, true);

  UPDATE public.orders SET status = 'completed'
  WHERE id IN (v_order_a, v_order_b);

  SELECT * INTO v_job_a FROM public.meinvoice_jobs WHERE order_id = v_order_a;
  SELECT * INTO v_job_b FROM public.meinvoice_jobs WHERE order_id = v_order_b;

  INSERT INTO _misa_results
  SELECT 'S1 entity A job snapshots store A entity',
         v_job_a.tax_entity_id = v_entity_a AND v_job_a.store_id = v_store_a,
         format('tax_entity_id=%s store_id=%s', v_job_a.tax_entity_id, v_job_a.store_id);

  INSERT INTO _misa_results
  SELECT 'S1 entity B job snapshots store B entity',
         v_job_b.tax_entity_id = v_entity_b AND v_job_b.store_id = v_store_b,
         format('tax_entity_id=%s store_id=%s', v_job_b.tax_entity_id, v_job_b.store_id);

  SELECT count(*) INTO v_count FROM public.meinvoice_jobs
  WHERE order_id IN (v_order_a, v_order_b);
  INSERT INTO _misa_results
  SELECT 'S1 exactly one job per order', v_count = 2, format('jobs=%s', v_count);

  -- S2: flip back and re-complete; ON CONFLICT (order_id) must not duplicate.
  UPDATE public.orders SET status = 'serving' WHERE id = v_order_a;
  UPDATE public.orders SET status = 'completed' WHERE id = v_order_a;

  SELECT count(*) INTO v_count FROM public.meinvoice_jobs WHERE order_id = v_order_a;
  INSERT INTO _misa_results
  SELECT 'S2 re-completion does not duplicate job', v_count = 1, format('jobs=%s', v_count);

  -- S3: staff meal never enqueues.
  INSERT INTO public.orders (id, restaurant_id, status, order_purpose)
  VALUES (v_order_staff, v_store_a, 'serving', 'staff_meal');
  INSERT INTO public.order_items
    (order_id, restaurant_id, menu_item_id, display_name, quantity, unit_price,
     status, vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax)
  VALUES (v_order_staff, v_store_a, v_menu_a, 'Staff dish', 1, 0, 'served', 0, 0, 0, 0);
  INSERT INTO public.payments
    (order_id, restaurant_id, method, amount, amount_portion, is_revenue)
  VALUES (v_order_staff, v_store_a, 'OTHER', 0, 0, false);
  UPDATE public.orders SET status = 'completed' WHERE id = v_order_staff;

  SELECT count(*) INTO v_count FROM public.meinvoice_jobs WHERE order_id = v_order_staff;
  INSERT INTO _misa_results
  SELECT 'S3 staff meal enqueues nothing', v_count = 0, format('jobs=%s', v_count);

  -- S4: no meinvoice_tax_entity_config rows exist for the fixtures, so the
  -- jobs must wait in pending_manual_config (never auto-pending).
  SELECT count(*) INTO v_count FROM public.meinvoice_jobs
  WHERE order_id IN (v_order_a, v_order_b)
    AND status = 'pending_manual_config';
  INSERT INTO _misa_results
  SELECT 'S4 unconfigured entities stay pending_manual_config',
         v_count = 2, format('pending_manual_config=%s', v_count);
END;
$test$;

DO $report$
DECLARE
  v_row record;
  v_failed int := 0;
BEGIN
  FOR v_row IN SELECT * FROM _misa_results ORDER BY scenario LOOP
    RAISE NOTICE '% | % | %',
      CASE WHEN v_row.ok THEN 'PASS' ELSE 'FAIL' END,
      v_row.scenario,
      v_row.detail;
    IF NOT v_row.ok THEN v_failed := v_failed + 1; END IF;
  END LOOP;
  IF v_failed > 0 THEN
    RAISE EXCEPTION 'meinvoice multi-entity contract: % scenario(s) failed', v_failed;
  END IF;
END;
$report$;

ROLLBACK;
