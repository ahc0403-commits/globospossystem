-- discount_staff_meal_contract_test.sql
-- Discount + Staff Meal V1 contract guard.
--
-- Run against a fully migrated local/staging database:
--   supabase test db
--
-- These assertions intentionally inspect the installed database objects, not
-- only migration text, so drift in process_payment / meInvoice trigger /
-- function grants is caught before deploy.

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(13);

CREATE TEMP TABLE _discount_staff_meal_results (
  scenario text,
  ok boolean,
  detail text
);

CREATE FUNCTION pg_temp.act_as(p_auth uuid) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config(
    'request.jwt.claims',
    json_build_object('sub', p_auth, 'role', 'authenticated')::text,
    true
  );
$$;

\set store_id      '''d5c00000-0000-4000-8000-000000000001'''
\set tax_entity_id '''d5c00000-0000-4000-8000-0000000000e1'''
\set admin_auth    '''d5c00000-0000-4000-8000-0000000000a0'''
\set waiter_auth   '''d5c00000-0000-4000-8000-0000000000a1'''
\set kitchen_auth  '''d5c00000-0000-4000-8000-0000000000a2'''
\set cashier_auth  '''d5c00000-0000-4000-8000-0000000000a3'''
\set menu_food     '''d5c00000-0000-4000-8000-0000000000f1'''
\set ingredient    '''d5c00000-0000-4000-8000-0000000000f2'''

INSERT INTO public.tax_entity (id, tax_code, name, owner_type, einvoice_provider, data_source)
VALUES (:tax_entity_id, '0318453299', 'Discount Staff Meal Test Entity', 'internal', 'meinvoice', 'VNPT_EPAY');

INSERT INTO public.restaurants (id, name, address, is_active, brand_id, tax_entity_id, vat_pricing_mode)
SELECT
  :store_id,
  'Discount Staff Meal Contract Store',
  'test',
  true,
  b.id,
  :tax_entity_id,
  'exclusive'
FROM public.brands b
WHERE b.code = 'globos_default'
LIMIT 1;

INSERT INTO auth.users (id, email)
VALUES
  (:admin_auth, 'dsm.admin@globos.test'),
  (:waiter_auth, 'dsm.waiter@globos.test'),
  (:kitchen_auth, 'dsm.kitchen@globos.test'),
  (:cashier_auth, 'dsm.cashier@globos.test');

INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active, extra_permissions, brand_id, primary_store_id)
SELECT actor.auth_id, :store_id, actor.role, actor.full_name, true, actor.extra_permissions, r.brand_id, :store_id
FROM public.restaurants r
CROSS JOIN (
  VALUES
    (:admin_auth::uuid, 'admin', 'DSM Admin', ARRAY[]::text[]),
    (:waiter_auth::uuid, 'waiter', 'DSM Waiter', ARRAY[]::text[]),
    (:kitchen_auth::uuid, 'kitchen', 'DSM Kitchen', ARRAY[]::text[]),
    (:cashier_auth::uuid, 'cashier', 'DSM Cashier', ARRAY['discount_apply']::text[])
) AS actor(auth_id, role, full_name, extra_permissions)
WHERE r.id = :store_id;

INSERT INTO public.user_store_access (user_id, store_id, is_primary, is_active, source_type)
SELECT u.id, :store_id, true, true, 'direct'
FROM public.users u
WHERE u.auth_id IN (:admin_auth, :waiter_auth, :kitchen_auth, :cashier_auth);

INSERT INTO public.menu_items (id, restaurant_id, name, price, is_available, vat_category)
VALUES (:menu_food, :store_id, 'DSM Food', 100000, true, 'food');

INSERT INTO public.inventory_items (id, restaurant_id, name, quantity, unit, current_stock, is_active)
VALUES (:ingredient, :store_id, 'DSM Ingredient', 1000, 'g', 1000, true);

INSERT INTO public.menu_recipes (restaurant_id, menu_item_id, ingredient_id, quantity_g)
VALUES (:store_id, :menu_food, :ingredient, 10);

INSERT INTO public.tables (restaurant_id, table_number, seat_count, status)
VALUES
  (:store_id, 'DSM1', 4, 'available'),
  (:store_id, 'DSM2', 4, 'available'),
  (:store_id, 'DSM3', 4, 'available'),
  (:store_id, 'DSM4', 4, 'available'),
  (:store_id, 'DSM5', 4, 'available');

DO $setup_pin$
BEGIN
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a0');
  PERFORM public.set_discount_manager_pin(
    'd5c00000-0000-4000-8000-000000000001',
    '2468'
  );
END;
$setup_pin$;

CREATE FUNCTION pg_temp.fixture_table(p_table_no text) RETURNS uuid
LANGUAGE sql AS $$
  SELECT id
  FROM public.tables
  WHERE restaurant_id = 'd5c00000-0000-4000-8000-000000000001'
    AND table_number = p_table_no;
$$;

CREATE FUNCTION pg_temp.new_customer_order(p_table_no text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_order public.orders;
BEGIN
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a1');
  v_order := public.create_order(
    'd5c00000-0000-4000-8000-000000000001',
    pg_temp.fixture_table(p_table_no),
    jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        'd5c00000-0000-4000-8000-0000000000f1',
        'quantity',
        1
      )
    )
  );
  RETURN v_order.id;
END;
$$;

CREATE FUNCTION pg_temp.ready_order(p_order_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_item record;
  v_step text;
BEGIN
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a2');
  FOR v_item IN
    SELECT id
    FROM public.order_items
    WHERE order_id = p_order_id
      AND status <> 'cancelled'
  LOOP
    FOREACH v_step IN ARRAY ARRAY['preparing', 'ready'] LOOP
      IF (SELECT status FROM public.order_items WHERE id = v_item.id) <> v_step THEN
        PERFORM public.update_order_item_status(
          v_item.id,
          'd5c00000-0000-4000-8000-000000000001',
          v_step
        );
      END IF;
    END LOOP;
  END LOOP;
END;
$$;

CREATE FUNCTION pg_temp.discount_proof(p_name text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
  VALUES (
    'discount-proofs',
    p_name,
    'd5c00000-0000-4000-8000-0000000000a3',
    'd5c00000-0000-4000-8000-0000000000a3',
    jsonb_build_object('mimetype', 'image/jpeg', 'size', 1)
  )
  ON CONFLICT (bucket_id, name) DO NOTHING;

  RETURN p_name;
END;
$$;

DO $process_payment_contract$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)
  INTO v_def;

  IF v_def ~* 'INSERT\s+INTO\s+(public\.)?einvoice_jobs' THEN
    RAISE EXCEPTION 'process_payment must not insert legacy einvoice_jobs';
  END IF;

  IF v_def ~* 'send_order_payload' THEN
    RAISE EXCEPTION 'process_payment must not rebuild legacy WeTax payloads';
  END IF;

  IF v_def !~ 'oi\.status NOT IN \(''ready'', ''served'', ''cancelled''\)' THEN
    RAISE EXCEPTION 'process_payment lost the I3 ready|served guard';
  END IF;

  IF v_def !~ 'PAYMENT_AMOUNT_EXCEEDS_REMAINING'
     OR v_def !~ 'PAYMENT_AMOUNT_INVALID' THEN
    RAISE EXCEPTION 'process_payment lost server-side amount validation';
  END IF;

  IF v_def !~ 'STAFF_MEAL_SERVICE_REQUIRED' THEN
    RAISE EXCEPTION 'process_payment must reject non-SERVICE staff-meal payments';
  END IF;

  IF v_def !~ 'v_payment_method_storage := ''OTHER''' THEN
    RAISE EXCEPTION 'process_payment lost SERVICE -> OTHER storage mapping';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('process_payment contract', true, 'no legacy einvoice insert; I3, amount check, SERVICE mapping present');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('process_payment contract', false, SQLERRM);
END;
$process_payment_contract$;

DO $discount_pin_return_contract$
DECLARE
  v_set_result text;
  v_clear_result text;
BEGIN
  SELECT pg_get_function_result('public.set_discount_manager_pin(uuid,text)'::regprocedure)
  INTO v_set_result;

  SELECT pg_get_function_result('public.clear_discount_manager_pin(uuid)'::regprocedure)
  INTO v_clear_result;

  IF v_set_result <> 'boolean' OR v_clear_result <> 'boolean' THEN
    RAISE EXCEPTION 'discount PIN set/clear must return boolean only, got set %, clear %',
      v_set_result, v_clear_result;
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('discount manager PIN return contract', true, 'set/clear return boolean and do not expose settings_json');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('discount manager PIN return contract', false, SQLERRM);
END;
$discount_pin_return_contract$;

DO $meinvoice_guard_contract$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure)
  INTO v_def;

  IF v_def !~ 'order_purpose' OR v_def !~ '''staff_meal''' THEN
    RAISE EXCEPTION 'meInvoice enqueue must skip staff_meal orders';
  END IF;

  IF v_def !~ 'p\.is_revenue = true' THEN
    RAISE EXCEPTION 'meInvoice enqueue must require at least one revenue payment';
  END IF;

  IF v_def !~* 'INSERT\s+INTO\s+(public\.)?meinvoice_jobs' THEN
    RAISE EXCEPTION 'meInvoice enqueue must remain the active MISA queue path';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('meinvoice staff-meal guard', true, 'staff_meal and non-revenue completions skipped');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('meinvoice staff-meal guard', false, SQLERRM);
END;
$meinvoice_guard_contract$;

DO $discount_helper_acl_contract$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public.calculate_order_discountable_total(uuid,uuid)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'calculate_order_discountable_total must not be directly executable by authenticated';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('discount helper ACL', true, 'internal helper is not directly callable by authenticated');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('discount helper ACL', false, SQLERRM);
END;
$discount_helper_acl_contract$;

DO $payment_zero_contract$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.payments'::regclass
      AND conname = 'payments_amount_check'
      AND pg_get_constraintdef(oid) ~ 'amount[[:space:]]*>=[[:space:]]*[(]*0'
  ) THEN
    RAISE EXCEPTION 'payments.amount must allow zero for fully discounted payments';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.payments'::regclass
      AND conname = 'payments_amount_portion_non_negative'
      AND pg_get_constraintdef(oid) ~ 'amount_portion[[:space:]]*>=[[:space:]]*[(]*0'
  ) THEN
    RAISE EXCEPTION 'payments.amount_portion must allow zero for fully discounted payments';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('zero payment constraints', true, 'payments amount constraints allow zero');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('zero payment constraints', false, SQLERRM);
END;
$payment_zero_contract$;

DO $discount_proof_storage_contract$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'storage_discount_proofs_select'
      AND cmd = 'SELECT'
      AND qual ILIKE '%discount-proofs%'
  ) THEN
    RAISE EXCEPTION 'discount proof storage must allow store-scoped SELECT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'storage_discount_proofs_insert'
      AND cmd = 'INSERT'
      AND with_check ILIKE '%discount-proofs%'
  ) THEN
    RAISE EXCEPTION 'discount proof storage must allow store-scoped INSERT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND (
        policyname LIKE 'storage_discount_proofs%'
        OR COALESCE(qual, '') ILIKE '%discount-proofs%'
        OR COALESCE(with_check, '') ILIKE '%discount-proofs%'
      )
      AND cmd IN ('ALL', 'UPDATE', 'DELETE')
  ) THEN
    RAISE EXCEPTION 'discount proof storage must not expose authenticated ALL/UPDATE/DELETE policies';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('discount proof storage ACL', true, 'proofs are readable/insertable but immutable to authenticated clients');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('discount proof storage ACL', false, SQLERRM);
END;
$discount_proof_storage_contract$;

DO $cashier_today_hcmc_window_contract$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.get_cashier_today_summary(uuid)'::regprocedure)
  INTO v_def;

  IF v_def !~ '::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh''' THEN
    RAISE EXCEPTION 'cashier today summary must convert Vietnam-local date back to HCMC timestamptz midnight';
  END IF;

  IF v_def !~ 'v_today_end := v_today_start \+ interval ''1 day''' THEN
    RAISE EXCEPTION 'cashier today summary must define an HCMC day upper bound';
  END IF;

  IF v_def !~ 'created_at < v_today_end' OR v_def !~ 'updated_at < v_today_end' THEN
    RAISE EXCEPTION 'cashier today summary must apply the upper bound to payments/orders/discounts';
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('cashier today HCMC window', true, 'uses HCMC midnight plus day upper bound');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('cashier today HCMC window', false, SQLERRM);
END;
$cashier_today_hcmc_window_contract$;

DO $discount_proof_existence_runtime$
DECLARE
  v_order_id uuid;
BEGIN
  v_order_id := pg_temp.new_customer_order('DSM5');
  PERFORM pg_temp.ready_order(v_order_id);

  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.apply_order_discount(
      v_order_id,
      'd5c00000-0000-4000-8000-000000000001',
      'promotion',
      'percent',
      10,
      'missing proof test',
      NULL,
      'd5c00000-0000-4000-8000-0000000000e1/d5c00000-0000-4000-8000-000000000001/2026-07-06/missing.jpg',
      '2468'
    );
    RAISE EXCEPTION 'missing discount proof path was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%DISCOUNT_PROOF_NOT_FOUND%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime discount proof existence', true, 'apply_order_discount rejects store-scoped paths with no storage object');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime discount proof existence', false, SQLERRM);
END;
$discount_proof_existence_runtime$;

DO $runtime_percent_discount_payment$
DECLARE
  v_order_id uuid;
  v_payment public.payments%ROWTYPE;
  v_order_status text;
  v_discount_status text;
  v_line_inc numeric;
BEGIN
  v_order_id := pg_temp.new_customer_order('DSM1');
  PERFORM pg_temp.ready_order(v_order_id);

  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  PERFORM public.apply_order_discount(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    'promotion',
    'percent',
    10,
    'runtime test',
    NULL,
    pg_temp.discount_proof('d5c00000-0000-4000-8000-0000000000e1/d5c00000-0000-4000-8000-000000000001/2026-07-06/runtime-percent.jpg'),
    '2468'
  );

  v_payment := public.process_payment(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    97200,
    'CASH'
  );

  SELECT status INTO v_order_status FROM public.orders WHERE id = v_order_id;
  SELECT status INTO v_discount_status FROM public.order_discounts WHERE order_id = v_order_id;
  SELECT paying_amount_inc_tax INTO v_line_inc
  FROM public.order_items
  WHERE order_id = v_order_id
    AND item_type = 'menu_item'
  LIMIT 1;

  IF v_payment.amount <> 97200 OR v_payment.method <> 'CASH' OR v_payment.is_revenue IS NOT TRUE THEN
    RAISE EXCEPTION 'discounted payment row mismatch: amount %, method %, is_revenue %',
      v_payment.amount, v_payment.method, v_payment.is_revenue;
  END IF;
  IF v_order_status <> 'completed' THEN
    RAISE EXCEPTION 'discounted order status % (expected completed)', v_order_status;
  END IF;
  IF v_discount_status <> 'consumed' THEN
    RAISE EXCEPTION 'discount status % (expected consumed)', v_discount_status;
  END IF;
  IF v_line_inc <> 97200 THEN
    RAISE EXCEPTION 'discounted line inc % (expected 97200)', v_line_inc;
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime percent discount payment', true, '10% discount consumed and discounted VAT line total paid');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime percent discount payment', false, SQLERRM);
END;
$runtime_percent_discount_payment$;

DO $runtime_split_discount_payment$
DECLARE
  v_order_id uuid;
  v_first_payment public.payments%ROWTYPE;
  v_second_payment public.payments%ROWTYPE;
  v_order_status text;
  v_discount_status text;
  v_payment_sum numeric;
  v_payment_count int;
BEGIN
  v_order_id := pg_temp.new_customer_order('DSM4');
  PERFORM pg_temp.ready_order(v_order_id);

  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  PERFORM public.apply_order_discount(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    'promotion',
    'percent',
    10,
    'runtime split discount test',
    NULL,
    pg_temp.discount_proof('d5c00000-0000-4000-8000-0000000000e1/d5c00000-0000-4000-8000-000000000001/2026-07-06/runtime-split.jpg'),
    '2468'
  );

  v_first_payment := public.process_payment(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    40000,
    'CASH'
  );

  SELECT status INTO v_order_status FROM public.orders WHERE id = v_order_id;
  SELECT status INTO v_discount_status FROM public.order_discounts WHERE order_id = v_order_id;

  IF v_first_payment.amount <> 40000 OR v_order_status <> 'serving' OR v_discount_status <> 'active' THEN
    RAISE EXCEPTION 'first split should keep order serving and discount active, got amount %, order %, discount %',
      v_first_payment.amount, v_order_status, v_discount_status;
  END IF;

  v_second_payment := public.process_payment(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    57200,
    'MOMO'
  );

  SELECT status INTO v_order_status FROM public.orders WHERE id = v_order_id;
  SELECT status INTO v_discount_status FROM public.order_discounts WHERE order_id = v_order_id;
  SELECT COALESCE(SUM(amount_portion), 0), COUNT(*)
  INTO v_payment_sum, v_payment_count
  FROM public.payments
  WHERE order_id = v_order_id;

  IF v_second_payment.amount <> 57200
     OR v_order_status <> 'completed'
     OR v_discount_status <> 'consumed'
     OR v_payment_sum <> 97200
     OR v_payment_count <> 2 THEN
    RAISE EXCEPTION 'split final mismatch: second %, order %, discount %, sum %, count %',
      v_second_payment.amount, v_order_status, v_discount_status, v_payment_sum, v_payment_count;
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime split discount payment', true, 'partial payment keeps discount active; final split consumes discount and completes order');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime split discount payment', false, SQLERRM);
END;
$runtime_split_discount_payment$;

DO $runtime_full_discount_zero_payment$
DECLARE
  v_order_id uuid;
  v_payment public.payments%ROWTYPE;
  v_order_status text;
  v_discount_status text;
BEGIN
  v_order_id := pg_temp.new_customer_order('DSM2');
  PERFORM pg_temp.ready_order(v_order_id);

  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  PERFORM public.apply_order_discount(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    'coupon',
    'amount',
    108000,
    'runtime zero payment test',
    'ZERO100',
    pg_temp.discount_proof('d5c00000-0000-4000-8000-0000000000e1/d5c00000-0000-4000-8000-000000000001/2026-07-06/runtime-zero.jpg'),
    '2468'
  );

  v_payment := public.process_payment(
    v_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    0,
    'CASH'
  );

  SELECT status INTO v_order_status FROM public.orders WHERE id = v_order_id;
  SELECT status INTO v_discount_status FROM public.order_discounts WHERE order_id = v_order_id;

  IF v_payment.amount <> 0 OR v_payment.amount_portion <> 0 THEN
    RAISE EXCEPTION 'zero discount payment row mismatch: amount %, portion %',
      v_payment.amount, v_payment.amount_portion;
  END IF;
  IF v_order_status <> 'completed' THEN
    RAISE EXCEPTION 'zero discount order status % (expected completed)', v_order_status;
  END IF;
  IF v_discount_status <> 'consumed' THEN
    RAISE EXCEPTION 'zero discount status % (expected consumed)', v_discount_status;
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime full discount zero payment', true, 'full discount allows zero payment and consumes discount');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime full discount zero payment', false, SQLERRM);
END;
$runtime_full_discount_zero_payment$;

DO $runtime_staff_meal_service_payment$
DECLARE
  v_revenue_order_id uuid;
  v_staff_order public.orders%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_revenue_jobs int;
  v_staff_jobs int;
  v_stock_before numeric;
  v_stock_after numeric;
  v_order_status text;
BEGIN
  v_revenue_order_id := pg_temp.new_customer_order('DSM3');
  PERFORM pg_temp.ready_order(v_revenue_order_id);
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  PERFORM public.process_payment(
    v_revenue_order_id,
    'd5c00000-0000-4000-8000-000000000001',
    108000,
    'CASH'
  );
  SELECT count(*) INTO v_revenue_jobs
  FROM public.meinvoice_jobs
  WHERE order_id = v_revenue_order_id;

  SELECT current_stock INTO v_stock_before
  FROM public.inventory_items
  WHERE id = 'd5c00000-0000-4000-8000-0000000000f2';

  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a1');
  v_staff_order := public.create_staff_meal_order(
    'd5c00000-0000-4000-8000-000000000001',
    jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        'd5c00000-0000-4000-8000-0000000000f1',
        'quantity',
        1
      )
    ),
    NULL,
    'runtime staff meal',
    '2468'
  );

  PERFORM pg_temp.ready_order(v_staff_order.id);
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  v_payment := public.process_payment(
    v_staff_order.id,
    'd5c00000-0000-4000-8000-000000000001',
    108000,
    'SERVICE'
  );

  SELECT status INTO v_order_status FROM public.orders WHERE id = v_staff_order.id;
  SELECT count(*) INTO v_staff_jobs FROM public.meinvoice_jobs WHERE order_id = v_staff_order.id;
  SELECT current_stock INTO v_stock_after FROM public.inventory_items WHERE id = 'd5c00000-0000-4000-8000-0000000000f2';

  IF v_revenue_jobs <> 1 THEN
    RAISE EXCEPTION 'control revenue order should enqueue one meInvoice job, got %', v_revenue_jobs;
  END IF;
  IF v_payment.method <> 'OTHER' OR v_payment.is_revenue IS NOT FALSE THEN
    RAISE EXCEPTION 'staff meal payment row mismatch: method %, is_revenue %',
      v_payment.method, v_payment.is_revenue;
  END IF;
  IF v_order_status <> 'completed' THEN
    RAISE EXCEPTION 'staff meal order status % (expected completed)', v_order_status;
  END IF;
  IF v_staff_jobs <> 0 THEN
    RAISE EXCEPTION 'staff meal must not enqueue meInvoice jobs, got %', v_staff_jobs;
  END IF;
  IF v_stock_after <> v_stock_before - 10 THEN
    RAISE EXCEPTION 'staff meal inventory stock % (expected %)', v_stock_after, v_stock_before - 10;
  END IF;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime staff meal service payment', true, 'SERVICE stored as OTHER/non-revenue, inventory deducted, no meInvoice job');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime staff meal service payment', false, SQLERRM);
END;
$runtime_staff_meal_service_payment$;

DO $runtime_staff_meal_non_service_rejected$
DECLARE
  v_staff_order public.orders%ROWTYPE;
BEGIN
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a1');
  v_staff_order := public.create_staff_meal_order(
    'd5c00000-0000-4000-8000-000000000001',
    jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        'd5c00000-0000-4000-8000-0000000000f1',
        'quantity',
        1
      )
    ),
    NULL,
    'runtime staff meal non-service rejection',
    '2468'
  );

  PERFORM pg_temp.ready_order(v_staff_order.id);
  PERFORM pg_temp.act_as('d5c00000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.process_payment(
      v_staff_order.id,
      'd5c00000-0000-4000-8000-000000000001',
      108000,
      'CASH'
    );
    RAISE EXCEPTION 'staff meal accepted non-SERVICE payment';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%STAFF_MEAL_SERVICE_REQUIRED%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime staff meal non-service rejected', true, 'staff meals cannot be closed as revenue payments');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _discount_staff_meal_results
  VALUES ('runtime staff meal non-service rejected', false, SQLERRM);
END;
$runtime_staff_meal_non_service_rejected$;

SELECT ok(ok, scenario || ': ' || detail)
FROM _discount_staff_meal_results
ORDER BY scenario;

SELECT * FROM finish();

ROLLBACK;
