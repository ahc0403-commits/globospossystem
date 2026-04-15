-- ============================================================
-- Office Integration Phase 0: Shared hierarchy tables
-- 2026-04-05
-- Creates: companies, brands tables
-- Modifies: restaurants (adds brand_id FK)
-- Non-breaking: brand_id is nullable, existing RLS unaffected
-- Related docs: Governance/OFFICE_INTEGRATION.md, ADR-012
-- ============================================================

-- ============================================================
-- COMPANIES (최상위 엔티티)
-- ============================================================
CREATE TABLE IF NOT EXISTS companies (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- RLS: 인증된 사용자만 SELECT
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'companies'
      AND policyname = 'authenticated_read'
  ) THEN
    CREATE POLICY "authenticated_read" ON companies
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
-- ============================================================
-- BRANDS (브랜드 그룹)
-- ============================================================
CREATE TABLE IF NOT EXISTS brands (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID REFERENCES companies(id),
  code       TEXT UNIQUE NOT NULL,
  name       TEXT NOT NULL,
  logo_url   TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_brands_company_id ON brands(company_id);
-- RLS: 인증된 사용자만 SELECT
ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'brands'
      AND policyname = 'authenticated_read'
  ) THEN
    CREATE POLICY "authenticated_read" ON brands
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
-- ============================================================
-- RESTAURANTS: brand_id FK 추가 (nullable, non-breaking)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurants'
      AND column_name = 'brand_id'
  ) THEN
    ALTER TABLE restaurants ADD COLUMN brand_id UUID REFERENCES brands(id);
    CREATE INDEX idx_restaurants_brand_id ON restaurants(brand_id);
    RAISE NOTICE 'Added brand_id to restaurants';
  ELSE
    RAISE NOTICE 'brand_id already exists on restaurants';
  END IF;
END $$;
