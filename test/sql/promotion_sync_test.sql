DO $$ BEGIN
  IF current_database() <> 'promotion_test' THEN
    RAISE EXCEPTION 'PROMOTION_TEST_DATABASE_REQUIRED';
  END IF;
END $$;
CREATE TRIGGER fixture_discount_write AFTER INSERT OR UPDATE OR DELETE
ON public.order_discounts FOR EACH ROW EXECUTE FUNCTION public.fixture_record_write();
CREATE TRIGGER fixture_line_write AFTER INSERT OR UPDATE OR DELETE
ON public.order_discount_lines FOR EACH ROW EXECUTE FUNCTION public.fixture_record_write();

CREATE FUNCTION public.fixture_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  TRUNCATE public.order_discount_lines, public.order_discounts,
    public.store_promotion_menu_items, public.store_promotions,
    public.order_items, public.menu_items, public.orders, public.restaurants;
  INSERT INTO public.restaurants(id) VALUES
    ('10000000-0000-0000-0000-000000000001'),
    ('10000000-0000-0000-0000-000000000002');
  INSERT INTO public.orders(id, restaurant_id) VALUES
    ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
  INSERT INTO public.menu_items(id, restaurant_id, vat_category) VALUES
    ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'food'),
    ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'alcohol'),
    ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'food');
  INSERT INTO public.store_promotions(id, restaurant_id, name, discount_percent,
    starts_at, ends_at, created_by) VALUES
    ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
     'Fixture promotion', 10, now() - interval '1 hour', now() + interval '1 hour',
     '20000000-0000-0000-0000-000000000001');
  INSERT INTO public.order_items(id, restaurant_id, order_id, menu_item_id, unit_price, quantity) VALUES
    ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
     '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 100, 1),
    ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
     '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 100, 1);
  TRUNCATE public.fixture_writes;
END $$;

CREATE FUNCTION public.fixture_sync(p_at timestamptz DEFAULT now())
RETURNS public.order_discounts LANGUAGE sql AS $$
  SELECT public.sync_active_order_promotion(
    '30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', p_at)
$$;
CREATE FUNCTION public.fixture_snapshot() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'headers', (SELECT jsonb_agg(to_jsonb(d) - ARRAY['id','created_at','updated_at'] ORDER BY status)
      FROM public.order_discounts d),
    'lines', (SELECT jsonb_agg(to_jsonb(l) - ARRAY['id','order_discount_id','created_at'] ORDER BY order_item_id)
      FROM public.order_discount_lines l))
$$;

SELECT set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', false);
DO $$
DECLARE
  v_store uuid := '10000000-0000-0000-0000-000000000001';
  v_order uuid := '30000000-0000-0000-0000-000000000001';
  v_promo uuid := '50000000-0000-0000-0000-000000000001';
  v_first_item uuid := '60000000-0000-0000-0000-000000000001';
  v_first_menu uuid := '40000000-0000-0000-0000-000000000001';
  v_discount public.order_discounts;
  v_before jsonb;
  v_lines_before jsonb;
  v_state text;
  v_error boolean;
BEGIN
  PERFORM fixture_reset();
  SELECT jsonb_agg(to_jsonb(d) ORDER BY id) INTO v_before FROM order_discounts d;
  SELECT jsonb_agg(to_jsonb(l) ORDER BY id) INTO v_lines_before FROM order_discount_lines l;
  FOR i IN 1..20 LOOP PERFORM refresh_store_order_promotions(v_store); END LOOP;
  RAISE NOTICE 'REPEATED_REFRESH_ROW_MUTATIONS=%', (SELECT count(*) FROM fixture_writes);
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes),
    '20 repeated cashier refreshes perform zero discount/line writes');
  PERFORM fixture_assert(v_before = (SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM order_discounts d)
    AND v_lines_before = (SELECT jsonb_agg(to_jsonb(l) ORDER BY id) FROM order_discount_lines l),
    'unchanged refresh preserves IDs, timestamps, header and exact allocations');
  PERFORM fixture_assert((SELECT discount_amount = 22 FROM order_discounts WHERE status = 'active')
    AND (SELECT sum(discount_amount) = 22 FROM order_discount_lines), 'exclusive food/alcohol VAT allocation');

  UPDATE store_promotions SET name = 'Renamed promotion';
  v_discount := fixture_sync();
  PERFORM fixture_assert(v_discount.reason = 'Renamed promotion'
    AND (SELECT count(*) = 1 FROM fixture_writes WHERE relation_name = 'order_discounts')
    AND (SELECT count(*) = 0 FROM fixture_writes WHERE relation_name = 'order_discount_lines')
    AND v_lines_before = (SELECT jsonb_agg(to_jsonb(l) ORDER BY id) FROM order_discount_lines l),
    'name-only edit updates one header and preserves allocation rows');

  TRUNCATE fixture_writes;
  UPDATE order_items SET status = 'served';
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'ready to served trigger does not rewrite discounts');
  UPDATE order_items SET paying_amount_inc_tax = 99, vat_rate = 8;
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'payment snapshot fields do not resync promotions');

  UPDATE order_items SET menu_item_id = '40000000-0000-0000-0000-000000000003' WHERE id = v_first_item;
  PERFORM fixture_assert((SELECT discount_amount = 22 FROM order_discounts WHERE status = 'active')
    AND (SELECT menu_item_id = '40000000-0000-0000-0000-000000000003'::uuid
      FROM order_discount_lines WHERE order_item_id = v_first_item), 'same-total menu replacement updates line metadata');
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes WHERE relation_name = 'order_discounts'),
    'allocation-only changes preserve header timestamp');

  PERFORM fixture_reset();
  UPDATE restaurants SET vat_pricing_mode = 'inclusive';
  PERFORM fixture_sync();
  UPDATE order_items SET unit_price = CASE WHEN id = v_first_item THEN 150 ELSE 50 END;
  PERFORM fixture_assert((SELECT discount_amount = 20 FROM order_discounts WHERE status = 'active')
    AND (SELECT discount_amount = 15 FROM order_discount_lines WHERE order_item_id = v_first_item),
    'equal order total with changed line proportions recalculates allocation');
  UPDATE order_items SET quantity = 2 WHERE id = v_first_item;
  PERFORM fixture_assert((SELECT discount_amount = 35 FROM order_discounts WHERE status = 'active'),
    'quantity change remains immediately synchronized');

  PERFORM fixture_reset();
  v_before := fixture_snapshot();
  DELETE FROM order_discount_lines WHERE order_item_id = v_first_item;
  TRUNCATE fixture_writes;
  PERFORM fixture_sync();
  PERFORM fixture_assert(fixture_snapshot() = v_before, 'missing allocation is repaired despite unchanged header');
  UPDATE order_discount_lines SET discount_amount = discount_amount - 1;
  PERFORM fixture_sync();
  PERFORM fixture_assert(fixture_snapshot() = v_before, 'corrupted allocation amounts are repaired');
  UPDATE order_discount_lines SET discount_percent = 9, restaurant_id = '10000000-0000-0000-0000-000000000002';
  PERFORM fixture_sync();
  PERFORM fixture_assert(fixture_snapshot() = v_before, 'allocation percent and store metadata are repaired');

  UPDATE store_promotions SET discount_percent = 20;
  PERFORM set_config('fixture.reject_line_insert', 'on', true);
  v_error := false;
  BEGIN PERFORM fixture_sync();
  EXCEPTION WHEN raise_exception THEN v_error := SQLERRM = 'FIXTURE_ALLOCATION_WRITE_FAILED'; END;
  PERFORM set_config('fixture.reject_line_insert', 'off', true);
  PERFORM fixture_assert(v_error AND fixture_snapshot() = v_before,
    'allocation write failure rolls back header and line changes atomically');

  -- Save/disable via the real admin RPC, including its open-order sync loop.
  PERFORM upsert_store_promotion_v2(v_store, v_promo, 'Selected menu', 25,
    now() - interval '1 hour', now() + interval '1 hour', 'selected_items', ARRAY[v_first_menu], true);
  PERFORM fixture_assert((SELECT discount_amount = 27 FROM order_discounts WHERE status = 'active')
    AND (SELECT count(*) = 1 AND min(order_item_id::text) = v_first_item::text FROM order_discount_lines),
    'admin menu-target edit applies exact scoped allocation');
  v_before := fixture_snapshot();
  TRUNCATE fixture_writes;
  PERFORM upsert_store_promotion_v2(v_store, v_promo, 'Selected menu', 25,
    now() - interval '1 hour', now() + interval '1 hour', 'selected_items', ARRAY[v_first_menu], true);
  PERFORM fixture_assert(fixture_snapshot() = v_before AND (SELECT count(*) = 0 FROM fixture_writes),
    're-saving the same campaign does not rewrite order discounts');
  PERFORM upsert_store_promotion_v2(v_store, v_promo, 'Selected menu', 25,
    now() - interval '1 hour', now() + interval '1 hour', 'selected_items', ARRAY[v_first_menu], false);
  PERFORM fixture_assert((SELECT count(*) = 0 FROM order_discounts WHERE status = 'active'), 'admin disable voids active promotion');
  TRUNCATE fixture_writes;
  PERFORM fixture_sync();
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'disabled campaign stays write-free');

  PERFORM fixture_reset();
  DELETE FROM order_discounts;
  UPDATE store_promotions SET starts_at = '2030-01-01 10:00+00', ends_at = '2030-01-01 11:00+00';
  TRUNCATE fixture_writes;
  v_discount := fixture_sync('2030-01-01 09:59:59+00');
  PERFORM fixture_assert(v_discount.id IS NULL AND (SELECT count(*) = 0 FROM fixture_writes), 'future campaign is not applied early');
  v_discount := fixture_sync('2030-01-01 10:00+00');
  PERFORM fixture_assert(v_discount.discount_amount = 22, 'campaign starts at inclusive boundary');
  TRUNCATE fixture_writes;
  PERFORM fixture_sync('2030-01-01 10:59:59+00');
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'active window refresh is write-free');
  PERFORM fixture_sync('2030-01-01 11:00+00');
  PERFORM fixture_sync('2030-01-01 11:01+00');
  PERFORM fixture_assert((SELECT count(*) = 1 FROM fixture_writes)
    AND (SELECT status = 'voided' AND void_reason = 'promotion_inactive' FROM order_discounts),
    'exclusive end boundary voids exactly once and retains history');

  PERFORM fixture_reset();
  UPDATE order_discounts SET approved_via = 'manager_pin', discount_type = 'coupon';
  v_before := fixture_snapshot();
  TRUNCATE fixture_writes;
  PERFORM fixture_sync(now() + interval '2 hours');
  PERFORM fixture_assert(fixture_snapshot() = v_before AND (SELECT count(*) = 0 FROM fixture_writes),
    'manual/coupon discount survives promotion expiry');
  PERFORM void_active_order_discount_for_item_change(v_order, v_store);
  PERFORM fixture_assert((SELECT count(*) = 1 FROM order_discounts WHERE status = 'active' AND approved_via = 'scheduled_promotion'),
    'existing explicit item-change invalidation still replaces manual discount');

  PERFORM fixture_reset();
  UPDATE order_items SET is_service_item = true WHERE id = v_first_item;
  PERFORM fixture_assert((SELECT discount_amount = 11 FROM order_discounts WHERE status = 'active')
    AND (SELECT count(*) = 1 FROM order_discount_lines), 'service item is excluded');
  UPDATE order_items SET status = 'cancelled' WHERE id <> v_first_item;
  PERFORM fixture_assert((SELECT count(*) = 0 FROM order_discounts WHERE status = 'active'), 'no eligible items voids discount');
  TRUNCATE fixture_writes;
  PERFORM fixture_sync();
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'empty eligible total stays write-free');

  FOREACH v_state IN ARRAY ARRAY['completed', 'cancelled'] LOOP
    PERFORM fixture_reset();
    UPDATE orders SET status = v_state;
    v_before := fixture_snapshot();
    PERFORM fixture_sync(now() + interval '2 hours');
    PERFORM fixture_assert(fixture_snapshot() = v_before AND (SELECT count(*) = 0 FROM fixture_writes),
      v_state || ' order preserves historical allocations');
  END LOOP;
  PERFORM fixture_reset();
  UPDATE orders SET order_purpose = 'staff_meal';
  PERFORM fixture_sync();
  PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'staff-meal order is not synchronized');
  v_discount := sync_active_order_promotion(v_order, '10000000-0000-0000-0000-000000000002');
  PERFORM fixture_assert(v_discount.id IS NULL AND (SELECT count(*) = 0 FROM fixture_writes), 'order/store mismatch does not write');

  PERFORM fixture_reset();
  UPDATE store_promotions SET channel = 'qr';
  PERFORM fixture_sync();
  PERFORM fixture_assert((SELECT count(*) = 0 FROM order_discounts WHERE status = 'active'), 'QR-only campaign does not apply to POS');
  UPDATE orders SET order_source = 'qr';
  v_discount := fixture_sync();
  PERFORM fixture_assert(v_discount.discount_amount = 22, 'QR order receives QR-only campaign');

  -- Differential arithmetic/persistence check against the exact old function.
  -- Exclude generated identifiers/timestamps; compare all financial metadata.
  FOR i IN 1..24 LOOP
    PERFORM fixture_reset();
    UPDATE restaurants SET vat_pricing_mode = CASE WHEN i % 2 = 0 THEN 'inclusive' ELSE 'exclusive' END;
    UPDATE store_promotions SET discount_percent = CASE WHEN i % 3 = 0 THEN 100 ELSE 33.33 END,
      scope = CASE WHEN i % 4 = 0 THEN 'selected_items' ELSE 'all_menu' END;
    INSERT INTO store_promotion_menu_items(promotion_id, restaurant_id, menu_item_id)
      VALUES (v_promo, v_store, v_first_menu);
    UPDATE order_items SET unit_price = CASE
        WHEN i % 3 = 0 THEN CASE WHEN id = v_first_item THEN 13700 ELSE 21900 END
        WHEN id = v_first_item THEN 1.37 * i ELSE 2.19 * i END,
      quantity = 1 + i % 3;
    DELETE FROM order_discounts;
    PERFORM fixture_original_sync(v_order, v_store);
    v_before := fixture_snapshot();
    DELETE FROM order_discounts;
    PERFORM fixture_sync();
    PERFORM fixture_assert(fixture_snapshot() = v_before, 'legacy calculation parity case ' || i);
    TRUNCATE fixture_writes;
    PERFORM fixture_sync();
    PERFORM fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'parity case remains write-free ' || i);
  END LOOP;

  -- Preserve the existing fail-closed behavior for fractional lines whose
  -- 100% whole-VND rounding would exceed the line gross. Fixing that pricing
  -- policy is outside this persistence-only change.
  PERFORM fixture_reset();
  UPDATE restaurants SET vat_pricing_mode = 'inclusive';
  UPDATE order_items SET unit_price = 1.6;
  DELETE FROM order_discounts;
  UPDATE store_promotions SET discount_percent = 100;
  v_error := false;
  BEGIN PERFORM fixture_original_sync(v_order, v_store);
  EXCEPTION WHEN check_violation THEN v_error := true; END;
  PERFORM fixture_assert(v_error, 'legacy rejects 100% fractional rounding above a line gross');
  v_error := false;
  BEGIN PERFORM fixture_sync();
  EXCEPTION WHEN check_violation THEN v_error := true; END;
  PERFORM fixture_assert(v_error AND (SELECT count(*) = 0 FROM order_discounts),
    'same invalid rounding still fails atomically without persisting a discount');

  PERFORM fixture_assert((SELECT definition = pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)
    FROM fixture_payment_contract), 'atomic payment wrapper definition is unchanged');
  PERFORM fixture_reset();
  v_error := false;
  BEGIN
    PERFORM refresh_store_order_promotions('10000000-0000-0000-0000-000000000002');
  EXCEPTION WHEN raise_exception THEN v_error := SQLERRM = 'PROMOTION_REFRESH_FORBIDDEN'; END;
  PERFORM fixture_assert(v_error, 'cashier cannot refresh another store');
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  v_error := false;
  BEGIN PERFORM refresh_store_order_promotions(v_store);
  EXCEPTION WHEN raise_exception THEN v_error := SQLERRM = 'PROMOTION_REFRESH_FORBIDDEN'; END;
  PERFORM fixture_assert(v_error, 'waiter cannot use cashier refresh');
  PERFORM set_config('request.jwt.claim.sub', '', true);
  v_error := false;
  BEGIN PERFORM refresh_store_order_promotions(v_store);
  EXCEPTION WHEN raise_exception THEN v_error := SQLERRM = 'PROMOTION_REFRESH_FORBIDDEN'; END;
  PERFORM fixture_assert(v_error, 'missing actor cannot refresh');
  PERFORM fixture_assert(NOT has_function_privilege('anon',
    'public.sync_active_order_promotion(uuid,uuid,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated',
    'public.sync_active_order_promotion(uuid,uuid,timestamptz)', 'EXECUTE'), 'internal sync stays inaccessible to public clients');
END $$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', false);
SELECT public.refresh_store_order_promotions('10000000-0000-0000-0000-000000000001');
RESET ROLE;
SELECT fixture_assert((SELECT count(*) = 0 FROM fixture_writes),
  'authenticated cashier refresh preserves unchanged allocations');
