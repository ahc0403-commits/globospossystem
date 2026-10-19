-- Test only in the disposable report fixture; every row change is rolled back.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'report_ready_test' THEN
    RAISE EXCEPTION 'TEST_DB_REQUIRED';
  END IF;
END $$;

INSERT INTO tax_entity VALUES
  ('8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1',
   'PENDING_SAMPLE_STORE_TAX_PROFILE', 'Non-fiscal SAMPLE');
INSERT INTO restaurants VALUES
  ('3a268807-771f-4fd4-84fe-e1b0b00de40a', 'BunsikClub SAMPLE', NULL,
   '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'),
  ('20000000-0000-0000-0000-000000000003', 'Another sample-entity store', NULL,
   '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1');
INSERT INTO orders VALUES
  ('30000000-0000-0000-0000-000000000004', 'completed', 'dine_in'),
  ('30000000-0000-0000-0000-000000000005', 'completed', 'dine_in');
INSERT INTO payments VALUES
  ('30000000-0000-0000-0000-000000000004', '3a268807-771f-4fd4-84fe-e1b0b00de40a',
   '2026-09-04 10:00+07', 189000, 189000, 'CASH', true),
  ('30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000003',
   '2026-09-04 11:00+07', 108000, 108000, 'CASH', true);
-- A stale production-seller invoice snapshot must not reintroduce SAMPLE.
INSERT INTO meinvoice_jobs VALUES
  ('50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
   'restaurant_pos', '2026-09-04 10:00+07', '10000000-0000-0000-0000-000000000001',
   'TM', '[]');

DO $$
DECLARE result jsonb; payment_count bigint;
BEGIN
  PERFORM set_config('fixture.super_admin', 'true', true);
  SELECT count(*) INTO payment_count FROM payments;
  result := get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
  PERFORM fixture_assert(result->>'status' = 'ready'
    AND result->>'entity_count' = '1'
    AND result#>>'{entities,0,receipt_count}' = '1'
    AND (result#>>'{entities,0,gross_sales}')::numeric = 150,
    'sample store and sample entity excluded; real split-payment total intact');
  PERFORM fixture_assert(result#>>'{entities,0,receipts,0,line_items,0,item_type}' = 'menu_item',
    'existing invoice VAT/item snapshots preserved');

  UPDATE restaurants SET name = 'Renamed training store',
    tax_entity_id = '10000000-0000-0000-0000-000000000001'
    WHERE id = '3a268807-771f-4fd4-84fe-e1b0b00de40a';
  result := get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
  PERFORM fixture_assert((result#>>'{entities,0,gross_sales}')::numeric = 150,
    'sample excluded even after rename or production-entity reassignment');

  -- The effective historical seller must also be non-fiscal-filtered even
  -- when the current store belongs to a production entity.
  UPDATE restaurants SET tax_entity_id = '10000000-0000-0000-0000-000000000001'
    WHERE id = '20000000-0000-0000-0000-000000000003';
  INSERT INTO store_tax_entity_history VALUES
    ('20000000-0000-0000-0000-000000000003', '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1',
     '2026-01-01+07', NULL, '2026-01-01+07');
  result := get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
  PERFORM fixture_assert(result->>'entity_count' = '1'
    AND (result#>>'{entities,0,gross_sales}')::numeric = 150,
    'historical sample seller excluded from report rollups');
  result := get_restaurant_daily_sales_export('2026-09-04');
  PERFORM fixture_assert((result->>'gross_sales')::numeric = 150
    AND result->>'receipt_count' = '1', 'legacy wrapper excludes sample too');
  PERFORM fixture_assert((SELECT count(*) FROM payments) = payment_count,
    'report reads preserve all historical payments');

  DELETE FROM payments WHERE restaurant_id = '20000000-0000-0000-0000-000000000001';
  result := get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04');
  PERFORM fixture_assert(result->>'status' = 'ready'
    AND result->>'entity_count' = '0' AND result->'entities' = '[]',
    'sample-only day has no tax-report entities');
  result := get_restaurant_daily_sales_export('2026-09-04');
  PERFORM fixture_assert((result->>'gross_sales')::numeric = 0
    AND result->>'receipt_count' = '0', 'sample-only legacy report is empty');
END $$;
ROLLBACK;
