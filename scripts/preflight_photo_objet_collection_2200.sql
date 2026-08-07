\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_monitoring_policies') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2200_REQUIRED_LEDGER_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-eod-2220-v3'
      AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_2200_ACTIVE_V3_POLICY_MISSING';
  END IF;
  IF (
    SELECT count(*)
    FROM public.photo_objet_monitoring_policies policy
    JOIN public.restaurants store ON store.id = policy.store_id
    WHERE policy.effective_to IS NULL
      AND policy.schedule_version = 'hcm-eod-2220-v3'
      AND policy.is_enabled = true
      AND store.is_active = true
  ) <> 6 THEN
    RAISE EXCEPTION 'PHOTO_2200_REQUIRES_SIX_ACTIVE_V3_STORES';
  END IF;
  IF to_regprocedure('public.photo_objet_ensure_expected_slots(date,date)') IS NULL
     OR to_regprocedure(
       'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2200_LEDGER_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'Photo Objet 22:00 collection preflight passed' AS result;
