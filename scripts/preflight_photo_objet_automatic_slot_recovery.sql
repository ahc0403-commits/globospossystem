\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.photo_objet_sales_pull_runs') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_REQUIRED_LEDGER_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_monitoring_policies
    WHERE schedule_version = 'hcm-eod-2200-v4'
      AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_ACTIVE_V4_POLICY_MISSING';
  END IF;
END
$preflight$;

SELECT 'Photo Objet automatic slot recovery preflight passed' AS result;
