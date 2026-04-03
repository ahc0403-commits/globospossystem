-- attendance_logs: add photo columns
ALTER TABLE attendance_logs
  ADD COLUMN IF NOT EXISTS photo_url TEXT,
  ADD COLUMN IF NOT EXISTS photo_thumbnail_url TEXT;

-- staff_wage_configs: payroll settings per staff
CREATE TABLE IF NOT EXISTS staff_wage_configs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  wage_type      TEXT NOT NULL CHECK (wage_type IN ('hourly','shift')),
  hourly_rate    DECIMAL(12,2),
  shift_rates    JSONB,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, effective_from)
);

ALTER TABLE staff_wage_configs ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'staff_wage_configs'
      AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON staff_wage_configs
      USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));
  END IF;
END $$;

-- payroll_records: computed payroll cache
CREATE TABLE IF NOT EXISTS payroll_records (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  total_hours   DECIMAL(8,2),
  total_amount  DECIMAL(12,2),
  breakdown     JSONB,
  status        TEXT DEFAULT 'draft' CHECK (status IN ('draft','confirmed','paid')),
  confirmed_by  UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE payroll_records ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'payroll_records'
      AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON payroll_records
      USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));
  END IF;
END $$;

-- Supabase Storage bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('attendance-photos', 'attendance-photos', false)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'restaurant_staff_access'
  ) THEN
    CREATE POLICY "restaurant_staff_access" ON storage.objects
      FOR ALL USING (
        bucket_id = 'attendance-photos'
        AND auth.role() = 'authenticated'
      );
  END IF;
END $$;
