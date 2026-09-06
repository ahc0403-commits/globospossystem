-- Clone the actual patched RPC and inject a clock only into the test clone.
DO $$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO definition;
  definition := replace(definition,
    'public.get_restaurant_daily_sales_exports_by_tax_entity(p_business_date date)',
    'public.fixture_sales_at(p_business_date date, p_at timestamptz)');
  EXECUTE replace(definition,'statement_timestamp()','p_at');
END $$;
DO $$
DECLARE result jsonb; at_time text;
BEGIN
  TRUNCATE restaurant_daily_sales_finalizations;
  PERFORM set_config('fixture.super_admin','true',true);
  UPDATE payments SET created_at = created_at - interval '12 hours';
  INSERT INTO order_items(id, order_id, display_name, quantity, unit_price,
    total_amount_ex_tax, vat_rate, vat_amount, created_at, status, is_service_item, item_type)
  VALUES ('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
    'Fixture meal', 1, 150, 150, 0, 0, '2026-09-04 09:00+07', 'served', false, 'menu_item');
  FOREACH at_time IN ARRAY ARRAY['10:00:00', '20:28:00', '21:59:59', '22:00:00', '22:19:59'] LOOP
    result := fixture_sales_at('2026-09-04', ('2026-09-04 ' || at_time || '+07')::timestamptz);
    PERFORM fixture_assert(result->>'status'='ready' AND result->>'finalized_at' IS NULL
      AND (result#>>'{entities,0,gross_sales}')::numeric=150
      AND result#>>'{entities,0,receipt_count}'='1', 'anytime download at ' || at_time);
    PERFORM fixture_assert(result#>>'{entities,0,receipts,0,line_items,0,item_type}'='menu_item',
      'VAT export fields preserved');
  END LOOP;
  PERFORM fixture_assert((result->>'report_ready_at')::timestamptz='2026-09-04 00:00+07'::timestamptz,
    'availability starts at HCM midnight');
  PERFORM fixture_assert(fixture_sales_at('2026-09-05','2026-09-04 23:59:59+07')->>'status'='pending',
    'future business date remains unavailable');
  PERFORM fixture_assert(fixture_sales_at('2026-09-05','2026-09-05 00:00:00+07')->>'status'='ready',
    'new day opens at midnight');
  PERFORM fixture_assert(fixture_sales_at('2026-09-03','2026-09-04 10:00+07')->'entities'='[]',
    'empty Restaurant result permits Photo-only reporting');
  INSERT INTO restaurant_daily_sales_finalizations VALUES('2026-09-04','data_integrity_failed',NULL);
  PERFORM fixture_assert(fixture_sales_at('2026-09-04','2026-09-04 22:20+07')->>'status'='data_integrity_failed',
    'confirmed integrity failures remain blocked');
  UPDATE restaurant_daily_sales_finalizations SET status='finalized', finalized_at='2026-09-04 22:20+07';
  PERFORM fixture_assert(fixture_sales_at('2026-09-04','2026-09-04 22:20+07')->>'status'='finalized',
    'audit finalization remains visible');
  TRUNCATE restaurant_daily_sales_finalizations;
  result := get_restaurant_daily_sales_export('2026-09-04');
  PERFORM fixture_assert(result->>'status'='ready' AND (result->>'gross_sales')::numeric=150,
    'legacy wrapper remains available');
  PERFORM set_config('fixture.super_admin','false',true);
  BEGIN
    PERFORM get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
    RAISE EXCEPTION 'Expected forbidden';
  EXCEPTION WHEN raise_exception THEN
    PERFORM fixture_assert(SQLERRM='RESTAURANT_SALES_EXPORT_FORBIDDEN','non-admin remains forbidden');
  END;
  PERFORM fixture_assert(NOT has_function_privilege('anon','get_restaurant_daily_sales_export(date)','EXECUTE')
    AND has_function_privilege('authenticated','get_restaurant_daily_sales_exports_by_tax_entity(date)','EXECUTE'),
    'RPC grants preserved');
END $$;
