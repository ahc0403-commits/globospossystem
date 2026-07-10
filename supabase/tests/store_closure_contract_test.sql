-- store_closure_contract_test.sql
-- Contract test for STORE_CLOSURE_V1 (20260709000000). Runs entirely inside a
-- transaction and rolls back — no data persists. Fails (non-zero) only if any
-- scenario does not meet the contract.
--
-- Run against a fully migrated database:
--   psql "$DB_URL" -f supabase/tests/store_closure_contract_test.sql
-- or via Supabase MCP execute_sql (final NOTICE surfaces the pass report).

BEGIN;

CREATE TEMP TABLE _r (scenario text, ok boolean, detail text);

DO $seed$
DECLARE
  v_super uuid;
  v_store uuid := 'c105e000-0000-4000-8000-000000000001';
  v_waiter uuid := 'c105e000-0000-4000-8000-0000000000a1';
  v_result jsonb;
  v_uas_after int;
  v_forbidden boolean := false;
  v_open_blocked boolean := false;
  v_pay_survives int;
  v_super_reads int;
BEGIN
  SELECT au.id INTO v_super
  FROM auth.users au JOIN public.users u ON u.auth_id = au.id
  WHERE u.role = 'super_admin' AND u.is_active LIMIT 1;

  IF v_super IS NULL THEN
    v_super := 'c105e000-0000-4000-8000-0000000000a0';
    INSERT INTO auth.users (id, email)
    VALUES (v_super, 'closure.contract.super@globos.test');
    INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active)
    VALUES (
      v_super,
      'aaaaaaaa-0000-0000-0000-000000000001',
      'super_admin',
      'Closure Contract Super',
      true
    );
  END IF;

  INSERT INTO restaurants (id, name, address, is_active, brand_id, tax_entity_id)
  SELECT v_store, 'Closure Contract Store', 'x', true, r.brand_id, r.tax_entity_id
  FROM restaurants r WHERE r.id = 'aaaaaaaa-0000-0000-0000-000000000001';

  INSERT INTO auth.users (id, email) VALUES (v_waiter, 'closure.contract.waiter@globos.test');
  INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_waiter, v_store, 'waiter', 'Closure Contract Waiter', true);
  INSERT INTO public.user_store_access (user_id, store_id, is_primary, is_active, source_type)
  SELECT id, v_store, true, true, 'direct' FROM public.users WHERE auth_id = v_waiter;

  -- tax data to preserve
  INSERT INTO orders (id, restaurant_id, status, created_by)
  VALUES ('c105e000-0000-4000-8000-00000000b001', v_store, 'completed', v_super);
  INSERT INTO payments (order_id, restaurant_id, amount, method, processed_by, is_revenue, amount_portion)
  VALUES ('c105e000-0000-4000-8000-00000000b001', v_store, 215000, 'CASH', v_super, true, 215000);
  INSERT INTO printer_destinations (restaurant_id, name, ip, port, purpose)
  VALUES (v_store, 'contract-kitchen', '10.0.0.9', 9100, 'kitchen');

  -- SC7: non-super_admin cannot close
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_waiter, 'role','authenticated')::text, true);
  BEGIN
    PERFORM admin_close_store(v_store, 'x');
    INSERT INTO _r VALUES ('SC7 non-super forbidden', false, 'close succeeded for waiter');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r VALUES ('SC7 non-super forbidden', SQLERRM LIKE '%STORE_CLOSE_FORBIDDEN%', SQLERRM);
  END;

  -- SC-reason: empty reason rejected
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_super, 'role','authenticated')::text, true);
  BEGIN
    PERFORM admin_close_store(v_store, '   ');
    INSERT INTO _r VALUES ('SC reason required', false, 'empty reason accepted');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r VALUES ('SC reason required', SQLERRM LIKE '%STORE_CLOSE_REASON_REQUIRED%', SQLERRM);
  END;

  -- SC1: open order blocks closure
  INSERT INTO orders (id, restaurant_id, status, created_by)
  VALUES ('c105e000-0000-4000-8000-00000000b002', v_store, 'serving', v_super);
  BEGIN
    PERFORM admin_close_store(v_store, 'try');
  EXCEPTION WHEN OTHERS THEN
    v_open_blocked := SQLERRM LIKE '%STORE_HAS_OPEN_ORDERS%';
  END;
  INSERT INTO _r VALUES ('SC1 open orders block', v_open_blocked, 'guard fired');
  -- settle it so SC2 can proceed
  UPDATE orders SET status = 'completed' WHERE id = 'c105e000-0000-4000-8000-00000000b002';

  -- SC2: successful closure
  v_result := admin_close_store(v_store, 'contract closure');
  INSERT INTO _r VALUES ('SC2 snapshot revenue',
    (v_result->'sales_snapshot'->>'lifetime_revenue') = '215000.00', v_result->'sales_snapshot'->>'lifetime_revenue');
  INSERT INTO _r VALUES ('SC2 store inactive',
    NOT (SELECT is_active FROM restaurants WHERE id = v_store), 'is_active');
  INSERT INTO _r VALUES ('SC2 access revoked',
    (v_result->>'access_rows_deactivated') = '1', v_result->>'access_rows_deactivated');
  INSERT INTO _r VALUES ('SC2 claims refreshed',
    (v_result->>'users_claims_refreshed')::int >= 1, v_result->>'users_claims_refreshed');
  INSERT INTO _r VALUES ('SC2 printers off',
    (v_result->>'printer_destinations_deactivated') = '1', v_result->>'printer_destinations_deactivated');

  -- SC3: waiter store scope now empty + mutation forbidden
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_waiter, 'role','authenticated')::text, true);
  SELECT count(*) INTO v_uas_after FROM user_accessible_stores(v_waiter) uas(store_id) WHERE uas.store_id = v_store;
  INSERT INTO _r VALUES ('SC3 uas empty after close', v_uas_after = 0, v_uas_after::text);
  BEGIN
    PERFORM create_order(v_store, NULL, jsonb_build_array(jsonb_build_object('menu_item_id','00000000-0000-0000-0000-000000000000','quantity',1)));
  EXCEPTION WHEN OTHERS THEN v_forbidden := true;
  END;
  INSERT INTO _r VALUES ('SC3 mutation forbidden', v_forbidden, 'create_order blocked');

  -- tax preservation: rows survive + super_admin still reads them
  SELECT count(*) INTO v_pay_survives FROM payments WHERE restaurant_id = v_store AND is_revenue;
  INSERT INTO _r VALUES ('SC-tax payment rows retained', v_pay_survives = 1, v_pay_survives::text);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_super, 'role','authenticated')::text, true);
  SELECT count(*) INTO v_super_reads FROM payments WHERE restaurant_id = v_store;
  INSERT INTO _r VALUES ('SC-tax super reads closed sales', v_super_reads >= 1, v_super_reads::text);

  -- SC6: re-close is rejected
  BEGIN
    PERFORM admin_close_store(v_store, 'again');
    INSERT INTO _r VALUES ('SC6 re-close blocked', false, 'second close succeeded');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _r VALUES ('SC6 re-close blocked', SQLERRM LIKE '%STORE_ALREADY_CLOSED%', SQLERRM);
  END;
END;
$seed$;

DO $report$
DECLARE r text; f int;
BEGIN
  SELECT string_agg((CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || scenario || CASE WHEN ok THEN '' ELSE ' :: ' || detail END, ' | ' ORDER BY scenario),
         count(*) FILTER (WHERE NOT ok)
  INTO r, f FROM _r;
  IF f > 0 THEN
    RAISE EXCEPTION 'STORE_CLOSURE_CONTRACT fail=% >>> %', f, r;
  END IF;
  RAISE NOTICE 'STORE_CLOSURE_CONTRACT fail=% >>> %', f, r;
END;
$report$;

ROLLBACK;
