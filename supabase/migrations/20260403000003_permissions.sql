ALTER TABLE users
  ADD COLUMN IF NOT EXISTS extra_permissions TEXT[] DEFAULT '{}';

CREATE TABLE IF NOT EXISTS restaurant_settings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE UNIQUE,
  payroll_pin     TEXT,
  settings_json   JSONB DEFAULT '{}',
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE restaurant_settings ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'restaurant_settings' AND policyname = 'admin_only'
  ) THEN
    CREATE POLICY "admin_only" ON restaurant_settings
      USING (
        restaurant_id = get_user_restaurant_id()
        AND has_any_role(ARRAY['admin','super_admin'])
      )
      WITH CHECK (
        restaurant_id = get_user_restaurant_id()
        AND has_any_role(ARRAY['admin','super_admin'])
      );
  END IF;
END $$;
