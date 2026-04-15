-- Office integration Phase 0: Brand seed data

WITH company_row AS (
  INSERT INTO companies (name)
  VALUES ('GLOBOSVN Co., Ltd.')
  ON CONFLICT DO NOTHING
  RETURNING id
),
company_id_resolved AS (
  SELECT id FROM company_row
  UNION ALL
  SELECT id FROM companies WHERE name = 'GLOBOSVN Co., Ltd.' LIMIT 1
)
INSERT INTO brands (company_id, code, name)
SELECT c.id, 'modern_k', 'Modern K Brunch & Bakery'
FROM company_id_resolved c
ON CONFLICT (code) DO NOTHING;
WITH company_row AS (
  SELECT id FROM companies WHERE name = 'GLOBOSVN Co., Ltd.' LIMIT 1
)
INSERT INTO brands (company_id, code, name)
SELECT c.id, 'k_noodle', 'K-Noodle'
FROM company_row c
ON CONFLICT (code) DO NOTHING;
WITH company_row AS (
  SELECT id FROM companies WHERE name = 'GLOBOSVN Co., Ltd.' LIMIT 1
)
INSERT INTO brands (company_id, code, name)
SELECT c.id, 'k_shabu', 'K-Shabu'
FROM company_row c
ON CONFLICT (code) DO NOTHING;
WITH company_row AS (
  SELECT id FROM companies WHERE name = 'GLOBOSVN Co., Ltd.' LIMIT 1
)
INSERT INTO brands (company_id, code, name)
SELECT c.id, 'globos_default', 'GLOBOS Default Brand'
FROM company_row c
ON CONFLICT (code) DO NOTHING;
-- Map existing restaurants to brands by name pattern
-- Uses case-insensitive ILIKE matching
-- Restaurants that don't match any pattern remain NULL (manual mapping needed)

UPDATE restaurants
SET brand_id = (
  SELECT id FROM brands WHERE code = 'modern_k' LIMIT 1
)
WHERE brand_id IS NULL
  AND (name ILIKE '%modern%k%' OR name ILIKE '%brunch%' OR name ILIKE '%bakery%');
UPDATE restaurants
SET brand_id = (
  SELECT id FROM brands WHERE code = 'k_noodle' LIMIT 1
)
WHERE brand_id IS NULL
  AND (name ILIKE '%noodle%' OR name ILIKE '%k-noodle%' OR name ILIKE '%knoodle%');
UPDATE restaurants
SET brand_id = (
  SELECT id FROM brands WHERE code = 'k_shabu' LIMIT 1
)
WHERE brand_id IS NULL
  AND (name ILIKE '%shabu%' OR name ILIKE '%k-shabu%' OR name ILIKE '%kshabu%');
UPDATE restaurants
SET brand_id = (
  SELECT id FROM brands WHERE code = 'globos_default' LIMIT 1
)
WHERE brand_id IS NULL;
-- Report unmapped restaurants (for manual review)
DO $$
DECLARE
  unmapped_count INT;
BEGIN
  SELECT COUNT(*) INTO unmapped_count FROM restaurants WHERE brand_id IS NULL;
  IF unmapped_count > 0 THEN
    RAISE NOTICE '% restaurants still unmapped (brand_id IS NULL). Manual mapping may be needed.', unmapped_count;
  ELSE
    RAISE NOTICE 'All restaurants successfully mapped to brands.';
  END IF;
END $$;
