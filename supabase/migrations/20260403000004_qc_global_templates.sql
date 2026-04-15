ALTER TABLE qc_templates
  ADD COLUMN IF NOT EXISTS is_global BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE qc_templates
  ALTER COLUMN restaurant_id DROP NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_global_check'
      AND conrelid = 'qc_templates'::regclass
  ) THEN
    ALTER TABLE qc_templates
      ADD CONSTRAINT qc_global_check
      CHECK (
        (is_global = TRUE AND restaurant_id IS NULL) OR
        (is_global = FALSE AND restaurant_id IS NOT NULL)
      );
  END IF;
END $$;
DROP POLICY IF EXISTS "restaurant_isolation" ON qc_templates;
DROP POLICY IF EXISTS "qc_templates_select" ON qc_templates;
DROP POLICY IF EXISTS "qc_templates_insert" ON qc_templates;
DROP POLICY IF EXISTS "qc_templates_update" ON qc_templates;
DROP POLICY IF EXISTS "qc_templates_delete" ON qc_templates;
CREATE POLICY "qc_templates_select" ON qc_templates
  FOR SELECT USING (
    is_global = TRUE OR
    restaurant_id = get_user_restaurant_id() OR
    has_any_role(ARRAY['super_admin'])
  );
CREATE POLICY "qc_templates_insert" ON qc_templates
  FOR INSERT WITH CHECK (
    has_any_role(ARRAY['super_admin']) OR
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );
CREATE POLICY "qc_templates_update" ON qc_templates
  FOR UPDATE USING (
    has_any_role(ARRAY['super_admin']) OR
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );
CREATE POLICY "qc_templates_delete" ON qc_templates
  FOR DELETE USING (
    has_any_role(ARRAY['super_admin']) OR
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );
