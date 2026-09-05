-- Apply the real migration unchanged. Clone only the grouped function with an
-- injected clock for deterministic 21:59:59/22:00 and HCM midnight boundaries.
DO $$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO definition;
  definition := replace(definition,
    'public.get_restaurant_daily_sales_exports_by_tax_entity(p_business_date date)',
    'public.fixture_sales_at(p_business_date date, p_at timestamptz)');
  definition := replace(definition,'statement_timestamp()','p_at');
  EXECUTE definition;
END $$;
DO $$
DECLARE result jsonb; after_finalize jsonb;
BEGIN
  TRUNCATE restaurant_daily_sales_finalizations;
  PERFORM set_config('fixture.super_admin','true',true);
  result := fixture_sales_at('2026-09-04','2026-09-04 21:59:59+07');
  PERFORM fixture_assert(result->>'status'='pending' AND result->'entities'='[]', '21:59:59 remains locked');
  result := fixture_sales_at('2026-09-04','2026-09-04 22:00:00+07');
  PERFORM fixture_assert(result->>'status'='ready' AND result->>'finalized_at' IS NULL
    AND (result->>'report_ready_at')::timestamptz='2026-09-04 22:00:00+07'::timestamptz,
    '22:00 opens without a 22:20 finalization marker');
  PERFORM fixture_assert(result->>'entity_count'='1'
    AND (result#>>'{entities,0,gross_sales}')::numeric=150
    AND result#>>'{entities,0,receipt_count}'='1',
    'split payments retain exact total; Photo and incomplete orders excluded');
  PERFORM fixture_assert((fixture_sales_at('2026-09-04','2026-09-05 00:00:00+07')->>'status')='ready',
    'past business date remains available after HCM midnight');
  PERFORM fixture_assert((fixture_sales_at('2026-09-05','2026-09-05 00:00:00+07')->>'status')='pending'
    AND (fixture_sales_at('2026-09-05','2026-09-04 23:59:59+07')->>'status')='pending',
    'new business day and future dates stay locked');
  PERFORM fixture_assert(fixture_sales_at('2026-09-03','2026-09-04 22:00:00+07')->'entities'='[]',
    'empty Restaurant date remains a valid ready export for combined Photo reporting');
  INSERT INTO restaurant_daily_sales_finalizations VALUES('2026-09-04','finalized','2026-09-04 22:20+07');
  after_finalize := fixture_sales_at('2026-09-04','2026-09-04 22:20+07');
  PERFORM fixture_assert(after_finalize->>'status'='finalized'
    AND after_finalize#>'{entities,0,receipts}'=result#>'{entities,0,receipts}',
    '22:20 audit preserves the previously available receipt contents');
  UPDATE restaurant_daily_sales_finalizations SET status='data_integrity_failed';
  result := fixture_sales_at('2026-09-04','2026-09-04 22:20+07');
  PERFORM fixture_assert(result->>'status'='data_integrity_failed' AND result->'entities'='[]',
    'confirmed integrity failure fails closed');
  TRUNCATE restaurant_daily_sales_finalizations;
  -- Call the unmodified clock and wrapper too, using an already-past date.
  result := get_restaurant_daily_sales_export('2026-09-04');
  PERFORM fixture_assert(result->>'status'='ready' AND (result->>'gross_sales')::numeric=150,
    'unmodified production clock and legacy wrapper execute the ready contract');
  PERFORM set_config('fixture.super_admin','false',true);
  BEGIN
    PERFORM get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
    RAISE EXCEPTION 'Expected forbidden';
  EXCEPTION WHEN raise_exception THEN
    PERFORM fixture_assert(SQLERRM='RESTAURANT_SALES_EXPORT_FORBIDDEN','non-admin cannot export');
  END;
  PERFORM fixture_assert(NOT has_function_privilege('anon','get_restaurant_daily_sales_export(date)','EXECUTE')
    AND has_function_privilege('authenticated','get_restaurant_daily_sales_exports_by_tax_entity(date)','EXECUTE'),
    'anonymous access blocked and authenticated RPC grant preserved');
END $$;
