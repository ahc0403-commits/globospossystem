-- ============================================================
-- QSC v2 Wave 0.5: qc_checks store-scoped uniqueness
-- 2026-05-07
-- Scope:
-- - widen qc_checks uniqueness from (template_id, check_date)
--   to (restaurant_id, template_id, check_date)
-- - align source write contract with global template visibility
-- Notes:
-- - current legacy uniqueness prevents the same global template from
--   being checked by multiple stores on the same date
-- - this migration should run before Wave 4 RPC extensions
-- ============================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.qc_checks'::regclass
      AND conname = 'qc_checks_template_id_check_date_key'
  ) THEN
    ALTER TABLE public.qc_checks
      DROP CONSTRAINT qc_checks_template_id_check_date_key;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.qc_checks'::regclass
      AND conname = 'qc_checks_restaurant_template_check_date_key'
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_restaurant_template_check_date_key
      UNIQUE (restaurant_id, template_id, check_date);
  END IF;
END $$;

COMMENT ON CONSTRAINT qc_checks_restaurant_template_check_date_key ON public.qc_checks IS
  'Ensures one QC/QSC result per store, template, and date while allowing global templates to be reused across stores.';
