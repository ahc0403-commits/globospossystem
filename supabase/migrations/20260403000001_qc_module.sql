-- QC 기준표 (매장 admin이 직접 생성/관리)
CREATE TABLE IF NOT EXISTS qc_templates (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  category           TEXT NOT NULL,
  criteria_text      TEXT NOT NULL,
  criteria_photo_url TEXT,
  sort_order         INT DEFAULT 0,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE qc_templates ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qc_templates'
      AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON qc_templates
      USING (
        restaurant_id = get_user_restaurant_id()
        OR has_any_role(ARRAY['super_admin'])
      );
  END IF;
END $$;
-- 일별 점검 기록
CREATE TABLE IF NOT EXISTS qc_checks (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  template_id        UUID NOT NULL REFERENCES qc_templates(id) ON DELETE CASCADE,
  check_date         DATE NOT NULL,
  checked_by         UUID REFERENCES auth.users(id),
  result             TEXT NOT NULL CHECK (result IN ('pass','fail','na')),
  evidence_photo_url TEXT,
  note               TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (template_id, check_date)
);
ALTER TABLE qc_checks ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qc_checks'
      AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON qc_checks
      USING (
        restaurant_id = get_user_restaurant_id()
        OR has_any_role(ARRAY['super_admin'])
      );
  END IF;
END $$;
-- Supabase Storage: qc-photos bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('qc-photos', 'qc-photos', false)
ON CONFLICT (id) DO NOTHING;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'authenticated_access_qc_photos'
  ) THEN
    CREATE POLICY "authenticated_access_qc_photos" ON storage.objects
      FOR ALL USING (
        bucket_id = 'qc-photos'
        AND auth.role() = 'authenticated'
      );
  END IF;
END $$;
