-- Disposable fixture only: real admin edits, trigger events and transaction rollback.
DO $$
DECLARE
  v_store uuid := '10000000-0000-0000-0000-000000000001';
  v_other_store uuid := '10000000-0000-0000-0000-000000000002';
  v_order uuid := '30000000-0000-0000-0000-000000000001';
  v_promo uuid := '50000000-0000-0000-0000-000000000001';
  v_menu_a uuid := '40000000-0000-0000-0000-000000000001';
  v_menu_b uuid := '40000000-0000-0000-0000-000000000002';
  v_before jsonb;
  v_other_before jsonb;
  v_lines_before jsonb;
  v_error boolean;
BEGIN
  IF current_database() <> 'promotion_test' THEN
    RAISE EXCEPTION 'PROMOTION_TEST_DATABASE_REQUIRED';
  END IF;
  PERFORM fixture_reset();
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
  UPDATE menu_items SET vat_category='food';
  PERFORM upsert_store_promotion_v2(v_store,v_promo,'Fixture promotion',10,
    now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_a],true);
  PERFORM fixture_assert((SELECT discount_amount=11 FROM order_discounts WHERE status='active'),
    'first selected menu has expected total discount');

  -- A same-store order and another store must not be caught by the new OR predicate.
  INSERT INTO orders(id,restaurant_id) VALUES
    ('30000000-0000-0000-0000-000000000002',v_store),
    ('30000000-0000-0000-0000-000000000003',v_other_store);
  INSERT INTO order_discounts(restaurant_id,order_id,discount_type,discount_mode,
    discount_value,discount_amount,reason,proof_storage_path,applied_by,approved_via)
  SELECT o.restaurant_id,o.id,'manual','amount',7,7,'Preserve manual discount',
    'fixture/manual','20000000-0000-0000-0000-000000000001','manager_pin'
  FROM orders o WHERE o.id <> v_order;
  SELECT jsonb_agg(to_jsonb(d) ORDER BY id) INTO v_other_before
    FROM order_discounts d WHERE order_id <> v_order;
  TRUNCATE fixture_writes,pos_live_events;
  PERFORM upsert_store_promotion_v2(v_store,v_promo,'Fixture promotion',10,
    now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_b],true);
  PERFORM fixture_assert((SELECT count(*)=1 FROM order_discount_lines WHERE menu_item_id=v_menu_b),
    'second equally priced target really replaces allocation');
  PERFORM fixture_assert((SELECT discount_amount=11 FROM order_discounts WHERE order_id=v_order),
    'changed menu preserves total discount');
  PERFORM fixture_assert((SELECT count(*)=1 FROM fixture_writes WHERE relation_name='order_discounts')
    AND (SELECT count(*)=1 FROM pos_live_events)
    AND (SELECT count(*)=1 FROM pos_live_events WHERE domain='orders'
      AND source_table='order_discounts' AND event_type='UPDATE' AND restaurant_id=v_store),
    'line-only admin edit emits exactly one store-scoped cashier invalidation');
  PERFORM fixture_assert(v_other_before=(SELECT jsonb_agg(to_jsonb(d) ORDER BY id)
    FROM order_discounts d WHERE order_id <> v_order),
    'same-store and cross-store unrelated discounts remain byte-for-byte unchanged');

  v_before := fixture_snapshot();
  SELECT jsonb_agg(to_jsonb(l) ORDER BY id) INTO v_lines_before FROM order_discount_lines l;
  TRUNCATE fixture_writes,pos_live_events;
  FOR i IN 1..20 LOOP PERFORM fixture_sync(); END LOOP;
  PERFORM upsert_store_promotion_v2(v_store,v_promo,'Fixture promotion',10,
    now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_b],true);
  PERFORM fixture_assert((SELECT count(*)=0 FROM fixture_writes)
    AND (SELECT count(*)=0 FROM pos_live_events) AND fixture_snapshot()=v_before,
    '20 unchanged syncs and an identical admin save emit no writes or feedback events');

  PERFORM upsert_store_promotion_v2(v_store,v_promo,'Renamed promotion',10,
    now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_b],true);
  PERFORM fixture_assert((SELECT count(*)=1 FROM pos_live_events)
    AND (SELECT count(*)=1 FROM fixture_writes WHERE relation_name='order_discounts')
    AND v_lines_before=(SELECT jsonb_agg(to_jsonb(l) ORDER BY id) FROM order_discount_lines l),
    'header-only edit emits one event and preserves line IDs and timestamps');

  v_before := fixture_snapshot();
  TRUNCATE fixture_writes,pos_live_events;
  PERFORM set_config('fixture.reject_line_insert','on',true);
  v_error := false;
  BEGIN
    PERFORM upsert_store_promotion_v2(v_store,v_promo,'Renamed promotion',10,
      now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_a],true);
  EXCEPTION WHEN raise_exception THEN v_error := SQLERRM='FIXTURE_ALLOCATION_WRITE_FAILED'; END;
  PERFORM set_config('fixture.reject_line_insert','off',true);
  PERFORM fixture_assert(v_error AND fixture_snapshot()=v_before
    AND (SELECT count(*)=0 FROM fixture_writes) AND (SELECT count(*)=0 FROM pos_live_events)
    AND (SELECT count(*)=1 FROM store_promotion_menu_items WHERE menu_item_id=v_menu_b),
    'failed line-only edit rolls back header, allocation, campaign targets and event atomically');

  PERFORM upsert_store_promotion_v2(v_store,v_promo,'Renamed promotion',20,
    now()-interval '1 hour',now()+interval '1 hour','selected_items',ARRAY[v_menu_b],true);
  PERFORM fixture_assert((SELECT discount_amount=22 FROM order_discounts WHERE order_id=v_order)
    AND (SELECT sum(discount_amount)=22 FROM order_discount_lines)
    AND (SELECT count(*)=1 FROM pos_live_events),
    'amount and allocation change together still emit only one event');

  -- Differential check of the replacement function against the exact historical
  -- calculation: both VAT modes, fractional values, quantities and menu scopes.
  FOR i IN 1..24 LOOP
    PERFORM fixture_reset();
    UPDATE restaurants SET vat_pricing_mode=CASE WHEN i%2=0 THEN 'inclusive' ELSE 'exclusive' END;
    UPDATE store_promotions SET discount_percent=CASE WHEN i%3=0 THEN 100 ELSE 33.33 END,
      scope=CASE WHEN i%4=0 THEN 'selected_items' ELSE 'all_menu' END;
    INSERT INTO store_promotion_menu_items(promotion_id,restaurant_id,menu_item_id)
      VALUES(v_promo,v_store,v_menu_a);
    UPDATE order_items SET unit_price=CASE
      WHEN i%3=0 THEN CASE WHEN menu_item_id=v_menu_a THEN 13700 ELSE 21900 END
      WHEN menu_item_id=v_menu_a THEN 1.37*i ELSE 2.19*i END, quantity=1+i%3;
    DELETE FROM order_discounts;
    PERFORM fixture_original_sync(v_order,v_store);
    v_before := fixture_snapshot();
    DELETE FROM order_discounts;
    TRUNCATE fixture_writes,pos_live_events;
    PERFORM fixture_sync();
    PERFORM fixture_assert(fixture_snapshot()=v_before
      AND (SELECT count(*)=1 FROM pos_live_events WHERE event_type='INSERT'),
      'replacement calculation parity and single insertion event case ' || i);
    TRUNCATE fixture_writes,pos_live_events;
    PERFORM fixture_sync();
    PERFORM fixture_assert((SELECT count(*)=0 FROM fixture_writes)
      AND (SELECT count(*)=0 FROM pos_live_events), 'replacement no-op case ' || i);
  END LOOP;
  PERFORM fixture_reset();
  TRUNCATE fixture_writes,pos_live_events;
END $$;
