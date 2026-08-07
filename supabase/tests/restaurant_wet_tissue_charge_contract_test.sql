\set ON_ERROR_STOP on

BEGIN;

DO $contract$
DECLARE
  v_store uuid := 'b8100000-0000-4000-8000-000000000001';
  v_auth uuid := 'b8100000-0000-4000-8000-000000000002';
  v_user uuid := 'b8100000-0000-4000-8000-000000000003';
  v_order uuid := 'b8100000-0000-4000-8000-000000000004';
  v_result jsonb;
  v_blocked boolean;
BEGIN
  INSERT INTO public.restaurants(
    id, name, address, is_active, brand_id, tax_entity_id
  )
  SELECT
    v_store, 'Wet Tissue Contract Store', 'test', true,
    restaurant.brand_id, restaurant.tax_entity_id
  FROM public.restaurants restaurant
  WHERE restaurant.brand_id IS NOT NULL
    AND restaurant.tax_entity_id IS NOT NULL
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WET_TISSUE_TEST_REQUIRES_STORE_FIXTURE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'wet.tissue.contract@invalid.local');
  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_user, v_auth, v_store, 'cashier', 'Wet Tissue Cashier', true
  );
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');
  INSERT INTO public.orders(
    id, restaurant_id, status, order_purpose, order_source, created_by
  ) VALUES (
    v_order, v_store, 'serving', 'customer', 'qr', v_auth
  );

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);

  v_result := public.set_order_wet_tissue_quantity(v_order, v_store, 2);
  IF (v_result->>'total_amount')::numeric <> 4000 THEN
    RAISE EXCEPTION 'WET_TISSUE_INITIAL_TOTAL_INVALID:%', v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.order_items item
    WHERE item.order_id = v_order
      AND item.item_type = 'wet_tissue_charge'
      AND item.quantity = 2
      AND item.unit_price = 2000
      AND item.paying_amount_inc_tax = 4000
      AND item.status = 'ready'
  ) THEN
    RAISE EXCEPTION 'WET_TISSUE_INITIAL_LINE_INVALID';
  END IF;

  PERFORM public.set_order_wet_tissue_quantity(v_order, v_store, 3);
  IF (
    SELECT count(*)
    FROM public.order_items item
    WHERE item.order_id = v_order
      AND item.item_type = 'wet_tissue_charge'
  ) <> 1 OR (
    SELECT item.paying_amount_inc_tax
    FROM public.order_items item
    WHERE item.order_id = v_order
      AND item.item_type = 'wet_tissue_charge'
  ) <> 6000 THEN
    RAISE EXCEPTION 'WET_TISSUE_UPSERT_NOT_IDEMPOTENT';
  END IF;

  PERFORM public.set_order_wet_tissue_quantity(v_order, v_store, 0);
  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE order_id = v_order AND item_type = 'wet_tissue_charge'
  ) THEN
    RAISE EXCEPTION 'WET_TISSUE_ZERO_DID_NOT_REMOVE_LINE';
  END IF;

  PERFORM public.set_order_wet_tissue_quantity(v_order, v_store, 4);
  IF (
    SELECT COALESCE(sum(paying_amount_inc_tax), 0)
    FROM public.order_items
    WHERE order_id = v_order AND status <> 'cancelled'
  ) <> 8000 THEN
    RAISE EXCEPTION 'WET_TISSUE_PAYMENT_TOTAL_INVALID';
  END IF;

  v_blocked := false;
  BEGIN
    PERFORM public.set_order_wet_tissue_quantity(v_order, v_store, 101);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%WET_TISSUE_QUANTITY_INVALID%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'WET_TISSUE_INVALID_QUANTITY_NOT_BLOCKED';
  END IF;

  INSERT INTO public.payments(
    restaurant_id, order_id, amount, amount_portion, method, processed_by
  ) VALUES (v_store, v_order, 1000, 1000, 'CASH', v_auth);

  v_blocked := false;
  BEGIN
    PERFORM public.set_order_wet_tissue_quantity(v_order, v_store, 5);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%WET_TISSUE_AFTER_PAYMENT%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'WET_TISSUE_AFTER_PAYMENT_NOT_BLOCKED';
  END IF;

  RAISE NOTICE 'RESTAURANT_WET_TISSUE_CHARGE_CONTRACT_PASS';
END;
$contract$;

ROLLBACK;
