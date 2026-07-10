-- service_item_exclusion_contract_test.sql
-- Runtime contract guard for Service Item Exclusion V1.
--
-- Run against a fully migrated local/staging database:
--   psql "$DB_URL" -f supabase/tests/service_item_exclusion_contract_test.sql
--
-- The test runs in one transaction and rolls back. It exercises the callable
-- RPC path for line-level service marking, split-payment protection, payment
-- math, inventory deduction, and meInvoice snapshot exclusion.

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(9);

CREATE TEMP TABLE _service_item_results (
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

\set store_id        '''5e710000-0000-4000-8000-000000000001'''
\set tax_entity_id   '''5e710000-0000-4000-8000-0000000000e1'''
\set admin_auth      '''5e710000-0000-4000-8000-0000000000a0'''
\set waiter_auth     '''5e710000-0000-4000-8000-0000000000a1'''
\set kitchen_auth    '''5e710000-0000-4000-8000-0000000000a2'''
\set cashier_auth    '''5e710000-0000-4000-8000-0000000000a3'''
\set no_perm_auth    '''5e710000-0000-4000-8000-0000000000a4'''
\set menu_billable   '''5e710000-0000-4000-8000-0000000000f1'''
\set menu_service    '''5e710000-0000-4000-8000-0000000000f2'''
\set ingredient      '''5e710000-0000-4000-8000-0000000000f3'''

INSERT INTO public.tax_entity (id, tax_code, name, owner_type, einvoice_provider, data_source)
VALUES (:tax_entity_id, '0318453299', 'Service Item Exclusion Test Entity', 'internal', 'meinvoice', 'VNPT_EPAY');

INSERT INTO public.restaurants (id, name, address, is_active, brand_id, tax_entity_id, vat_pricing_mode)
SELECT
  :store_id,
  'Service Item Exclusion Contract Store',
  'test',
  true,
  b.id,
  :tax_entity_id,
  'exclusive'
FROM public.brands b
WHERE b.code = 'globos_default'
LIMIT 1;

UPDATE public.brands
SET service_charge_enabled = true,
    service_charge_rate = 10
WHERE id = (
  SELECT brand_id
  FROM public.restaurants
  WHERE id = :store_id
);

INSERT INTO auth.users (id, email)
VALUES
  (:admin_auth, 'svc.admin@globos.test'),
  (:waiter_auth, 'svc.waiter@globos.test'),
  (:kitchen_auth, 'svc.kitchen@globos.test'),
  (:cashier_auth, 'svc.cashier@globos.test'),
  (:no_perm_auth, 'svc.no-perm@globos.test');

INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active, extra_permissions, brand_id, primary_store_id)
SELECT actor.auth_id, :store_id, actor.role, actor.full_name, true, actor.extra_permissions, r.brand_id, :store_id
FROM public.restaurants r
CROSS JOIN (
  VALUES
    (:admin_auth::uuid, 'admin', 'Service Admin', ARRAY[]::text[]),
    (:waiter_auth::uuid, 'waiter', 'Service Waiter', ARRAY[]::text[]),
    (:kitchen_auth::uuid, 'kitchen', 'Service Kitchen', ARRAY[]::text[]),
    (:cashier_auth::uuid, 'cashier', 'Service Cashier', ARRAY['discount_apply']::text[]),
    (:no_perm_auth::uuid, 'cashier', 'Service No Permission', ARRAY[]::text[])
) AS actor(auth_id, role, full_name, extra_permissions)
WHERE r.id = :store_id;

INSERT INTO public.user_store_access (user_id, store_id, is_primary, is_active, source_type)
SELECT u.id, :store_id, true, true, 'direct'
FROM public.users u
WHERE u.auth_id IN (:admin_auth, :waiter_auth, :kitchen_auth, :cashier_auth, :no_perm_auth);

INSERT INTO public.menu_items (id, restaurant_id, name, price, is_available, vat_category)
VALUES
  (:menu_billable, :store_id, 'Service Contract Billable Food', 100000, true, 'food'),
  (:menu_service, :store_id, 'Service Contract Provided Food', 50000, true, 'food');

INSERT INTO public.inventory_items (id, restaurant_id, name, quantity, unit, current_stock, is_active)
VALUES (:ingredient, :store_id, 'Service Contract Ingredient', 1000, 'g', 1000, true);

INSERT INTO public.menu_recipes (restaurant_id, menu_item_id, ingredient_id, quantity_g)
VALUES
  (:store_id, :menu_billable, :ingredient, 10),
  (:store_id, :menu_service, :ingredient, 5);

INSERT INTO public.tables (restaurant_id, table_number, seat_count, status)
SELECT :store_id, 'SIE' || n, 4, 'available'
FROM generate_series(1, 8) n;

DO $setup_pin$
BEGIN
  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a0');
  PERFORM public.set_discount_manager_pin(
    '5e710000-0000-4000-8000-000000000001',
    '2468'
  );
END;
$setup_pin$;

CREATE FUNCTION pg_temp.fixture_table(p_table_no text) RETURNS uuid
LANGUAGE sql AS $$
  SELECT id
  FROM public.tables
  WHERE restaurant_id = '5e710000-0000-4000-8000-000000000001'
    AND table_number = p_table_no;
$$;

CREATE FUNCTION pg_temp.new_customer_order(p_table_no text, p_include_service_candidate boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_payload jsonb;
  v_order public.orders;
BEGIN
  v_payload := jsonb_build_array(
    jsonb_build_object(
      'menu_item_id',
      '5e710000-0000-4000-8000-0000000000f1',
      'quantity',
      1
    )
  );

  IF p_include_service_candidate THEN
    v_payload := v_payload || jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        '5e710000-0000-4000-8000-0000000000f2',
        'quantity',
        1
      )
    );
  END IF;

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a1');
  v_order := public.create_order(
    '5e710000-0000-4000-8000-000000000001',
    pg_temp.fixture_table(p_table_no),
    v_payload
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
  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a2');
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
          '5e710000-0000-4000-8000-000000000001',
          v_step
        );
      END IF;
    END LOOP;
  END LOOP;
END;
$$;

CREATE FUNCTION pg_temp.service_candidate(p_order_id uuid) RETURNS uuid
LANGUAGE sql AS $$
  SELECT id
  FROM public.order_items
  WHERE order_id = p_order_id
    AND menu_item_id = '5e710000-0000-4000-8000-0000000000f2'
  ORDER BY created_at, id
  LIMIT 1;
$$;

CREATE FUNCTION pg_temp.billable_candidate(p_order_id uuid) RETURNS uuid
LANGUAGE sql AS $$
  SELECT id
  FROM public.order_items
  WHERE order_id = p_order_id
    AND menu_item_id = '5e710000-0000-4000-8000-0000000000f1'
  ORDER BY created_at, id
  LIMIT 1;
$$;

DO $function_acl_contract$
BEGIN
  IF NOT has_function_privilege(
    'authenticated',
    'public.mark_order_item_service(uuid,uuid,text,text)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated clients must be able to call mark_order_item_service';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.unmark_order_item_service(uuid,uuid,text,text)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated clients must be able to call unmark_order_item_service';
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.calculate_order_discountable_total(uuid,uuid)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'discountable-total helper must remain service_role-only';
  END IF;

  INSERT INTO _service_item_results
  VALUES ('function ACL contract', true, 'mark/unmark callable; internal helper not directly callable');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('function ACL contract', false, SQLERRM);
END;
$function_acl_contract$;

DO $runtime_mark_unmark_auto_void$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
  v_discount_id uuid;
  v_item public.order_items%ROWTYPE;
  v_discount_status text;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE1');
  PERFORM pg_temp.ready_order(v_order_id);
  v_item_id := pg_temp.service_candidate(v_order_id);

  INSERT INTO public.order_discounts (
    restaurant_id,
    order_id,
    discount_type,
    discount_mode,
    discount_value,
    discount_amount,
    reason,
    proof_storage_path,
    applied_by
  )
  VALUES (
    '5e710000-0000-4000-8000-000000000001',
    v_order_id,
    'manual',
    'amount',
    10000,
    10000,
    'auto-void runtime fixture',
    'service-item-contract/proof.jpg',
    '5e710000-0000-4000-8000-0000000000a3'
  )
  RETURNING id INTO v_discount_id;

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  v_item := public.mark_order_item_service(
    v_item_id,
    '5e710000-0000-4000-8000-000000000001',
    'guest recovery',
    '2468'
  );

  SELECT status INTO v_discount_status
  FROM public.order_discounts
  WHERE id = v_discount_id;

  IF v_item.is_service_item IS NOT TRUE
     OR v_item.service_reason <> 'guest recovery'
     OR v_item.vat_amount <> 0
     OR v_item.total_amount_ex_tax <> 0
     OR v_item.paying_amount_inc_tax <> 0
     OR v_discount_status <> 'voided' THEN
    RAISE EXCEPTION 'mark mismatch: service %, reason %, vat %, ex %, inc %, discount %',
      v_item.is_service_item,
      v_item.service_reason,
      v_item.vat_amount,
      v_item.total_amount_ex_tax,
      v_item.paying_amount_inc_tax,
      v_discount_status;
  END IF;

  v_item := public.unmark_order_item_service(
    v_item_id,
    '5e710000-0000-4000-8000-000000000001',
    'manager reversed',
    '2468'
  );

  IF v_item.is_service_item IS TRUE
     OR v_item.service_reason IS NOT NULL
     OR v_item.service_marked_by IS NOT NULL
     OR v_item.service_marked_at IS NOT NULL THEN
    RAISE EXCEPTION 'unmark did not clear active service state';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.audit_logs
    WHERE entity_id = v_item_id
      AND action IN ('mark_order_item_service', 'unmark_order_item_service')
  ) THEN
    RAISE EXCEPTION 'mark/unmark audit evidence missing';
  END IF;

  INSERT INTO _service_item_results
  VALUES ('runtime mark/unmark and discount auto-void', true, 'service evidence written, active discount voided, unmark clears active state and audits');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime mark/unmark and discount auto-void', false, SQLERRM);
END;
$runtime_mark_unmark_auto_void$;

DO $runtime_payment_math_inventory_meinvoice$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
  v_payment public.payments%ROWTYPE;
  v_order_status text;
  v_service_line public.order_items%ROWTYPE;
  v_service_charge_total numeric;
  v_stock_before numeric;
  v_stock_after numeric;
  v_job public.meinvoice_jobs%ROWTYPE;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE2');
  PERFORM pg_temp.ready_order(v_order_id);
  v_item_id := pg_temp.service_candidate(v_order_id);

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  PERFORM public.mark_order_item_service(
    v_item_id,
    '5e710000-0000-4000-8000-000000000001',
    'promo tasting',
    '2468'
  );

  SELECT current_stock INTO v_stock_before
  FROM public.inventory_items
  WHERE id = '5e710000-0000-4000-8000-0000000000f3';

  v_payment := public.process_payment(
    v_order_id,
    '5e710000-0000-4000-8000-000000000001',
    118800,
    'CASH'
  );

  SELECT status INTO v_order_status
  FROM public.orders
  WHERE id = v_order_id;

  SELECT * INTO v_service_line
  FROM public.order_items
  WHERE id = v_item_id;

  SELECT COALESCE(SUM(paying_amount_inc_tax), 0)
  INTO v_service_charge_total
  FROM public.order_items
  WHERE order_id = v_order_id
    AND item_type = 'service_charge';

  SELECT current_stock INTO v_stock_after
  FROM public.inventory_items
  WHERE id = '5e710000-0000-4000-8000-0000000000f3';

  SELECT * INTO v_job
  FROM public.meinvoice_jobs
  WHERE order_id = v_order_id;

  IF v_payment.amount <> 118800
     OR v_payment.amount_portion <> 118800
     OR v_order_status <> 'completed'
     OR v_service_charge_total <> 10800
     OR v_stock_after <> v_stock_before - 15
     OR v_service_line.vat_amount <> 0
     OR v_service_line.total_amount_ex_tax <> 0
     OR v_service_line.paying_amount_inc_tax <> 0 THEN
    RAISE EXCEPTION 'payment mismatch: amount %, portion %, order %, sc %, stock before/after %/%, service vat/ex/inc %/%/%',
      v_payment.amount,
      v_payment.amount_portion,
      v_order_status,
      v_service_charge_total,
      v_stock_before,
      v_stock_after,
      v_service_line.vat_amount,
      v_service_line.total_amount_ex_tax,
      v_service_line.paying_amount_inc_tax;
  END IF;

  IF v_job.id IS NULL THEN
    RAISE EXCEPTION 'revenue payment did not enqueue meInvoice job';
  END IF;

  IF v_job.line_items_snapshot @> jsonb_build_array(jsonb_build_object('order_item_id', v_item_id)) THEN
    RAISE EXCEPTION 'meInvoice snapshot contains service item line %', v_item_id;
  END IF;

  IF NOT (v_job.line_items_snapshot @> jsonb_build_array(jsonb_build_object('order_item_id', pg_temp.billable_candidate(v_order_id)))) THEN
    RAISE EXCEPTION 'meInvoice snapshot lost billable menu line';
  END IF;

  INSERT INTO _service_item_results
  VALUES ('runtime payment math, inventory, meInvoice', true, 'service line excluded from payable/SC/meInvoice but stock deducted');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime payment math, inventory, meInvoice', false, SQLERRM);
END;
$runtime_payment_math_inventory_meinvoice$;

DO $runtime_split_payment_blocks_mark$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE3');
  PERFORM pg_temp.ready_order(v_order_id);
  v_item_id := pg_temp.service_candidate(v_order_id);

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  PERFORM public.process_payment(
    v_order_id,
    '5e710000-0000-4000-8000-000000000001',
    50000,
    'CASH'
  );

  BEGIN
    PERFORM public.mark_order_item_service(
      v_item_id,
      '5e710000-0000-4000-8000-000000000001',
      'too late',
      '2468'
    );
    RAISE EXCEPTION 'service mark accepted after a payment row exists';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SERVICE_MARK_AFTER_PAYMENT%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime split payment blocks mark', true, 'mark is rejected after any payment row exists');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime split payment blocks mark', false, SQLERRM);
END;
$runtime_split_payment_blocks_mark$;

DO $runtime_unprovided_item_guard$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE7');
  v_item_id := pg_temp.service_candidate(v_order_id);

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.mark_order_item_service(
      v_item_id,
      '5e710000-0000-4000-8000-000000000001',
      'not cooked yet',
      '2468'
    );
    RAISE EXCEPTION 'pending item accepted service mark';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SERVICE_MARK_ITEM_NOT_PROVIDED%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime unprovided item guard', true, 'pending/preparing items cannot be marked service before ready or served');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime unprovided item guard', false, SQLERRM);
END;
$runtime_unprovided_item_guard$;

DO $runtime_staff_meal_blocks_mark$
DECLARE
  v_staff_order public.orders%ROWTYPE;
  v_item_id uuid;
BEGIN
  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a1');
  v_staff_order := public.create_staff_meal_order(
    '5e710000-0000-4000-8000-000000000001',
    jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        '5e710000-0000-4000-8000-0000000000f1',
        'quantity',
        1
      )
    ),
    NULL,
    'staff meal service item rejection',
    '2468'
  );

  SELECT id INTO v_item_id
  FROM public.order_items
  WHERE order_id = v_staff_order.id
  LIMIT 1;

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.mark_order_item_service(
      v_item_id,
      '5e710000-0000-4000-8000-000000000001',
      'staff meal duplicate concept',
      '2468'
    );
    RAISE EXCEPTION 'staff meal accepted line-level service mark';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SERVICE_MARK_PURPOSE_UNSUPPORTED%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime staff meal blocks mark', true, 'staff meal line-level service marking is rejected');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime staff meal blocks mark', false, SQLERRM);
END;
$runtime_staff_meal_blocks_mark$;

DO $runtime_full_service_guard$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE4', false);
  PERFORM pg_temp.ready_order(v_order_id);
  v_item_id := pg_temp.billable_candidate(v_order_id);

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.mark_order_item_service(
      v_item_id,
      '5e710000-0000-4000-8000-000000000001',
      'would make full service',
      '2468'
    );
    RAISE EXCEPTION 'full line-level service order was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%FULL_SERVICE_NOT_ALLOWED%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime full-service guard', true, 'last billable menu line cannot be marked service');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime full-service guard', false, SQLERRM);
END;
$runtime_full_service_guard$;

DO $runtime_service_charge_type_guard$
DECLARE
  v_order_id uuid;
  v_charge_id uuid := gen_random_uuid();
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE5', false);

  INSERT INTO public.order_items (
    id,
    restaurant_id,
    order_id,
    menu_item_id,
    item_type,
    label,
    display_name,
    unit_price,
    quantity,
    status
  )
  VALUES (
    v_charge_id,
    '5e710000-0000-4000-8000-000000000001',
    v_order_id,
    NULL,
    'service_charge',
    'Manual Service Charge',
    'Manual Service Charge',
    1000,
    1,
    'served'
  );

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a3');
  BEGIN
    PERFORM public.mark_order_item_service(
      v_charge_id,
      '5e710000-0000-4000-8000-000000000001',
      'not a menu item',
      '2468'
    );
    RAISE EXCEPTION 'service_charge line accepted service mark';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SERVICE_MARK_ITEM_TYPE%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime service-charge type guard', true, 'synthetic service_charge line cannot be marked service item');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime service-charge type guard', false, SQLERRM);
END;
$runtime_service_charge_type_guard$;

DO $runtime_permission_guard$
DECLARE
  v_order_id uuid;
  v_item_id uuid;
BEGIN
  v_order_id := pg_temp.new_customer_order('SIE6');
  PERFORM pg_temp.ready_order(v_order_id);
  v_item_id := pg_temp.service_candidate(v_order_id);

  PERFORM pg_temp.act_as('5e710000-0000-4000-8000-0000000000a4');
  BEGIN
    PERFORM public.mark_order_item_service(
      v_item_id,
      '5e710000-0000-4000-8000-000000000001',
      'cashier without permission',
      '2468'
    );
    RAISE EXCEPTION 'cashier without discount_apply accepted service mark';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SERVICE_MARK_FORBIDDEN%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO _service_item_results
  VALUES ('runtime permission guard', true, 'cashier without discount_apply cannot mark service item');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _service_item_results
  VALUES ('runtime permission guard', false, SQLERRM);
END;
$runtime_permission_guard$;

SELECT ok(ok, scenario || ': ' || detail)
FROM _service_item_results
ORDER BY scenario;

SELECT * FROM finish();

ROLLBACK;
