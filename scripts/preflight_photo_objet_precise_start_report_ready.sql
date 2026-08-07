\set ON_ERROR_STOP on

DO $preflight$
DECLARE
  v_open_v4 integer;
BEGIN
  IF to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.photo_objet_sales_pull_runs') IS NULL
     OR to_regclass('public.photo_objet_sales_raw') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_REQUIRED_LEDGER_MISSING';
  END IF;
  SELECT count(*) INTO v_open_v4
  FROM public.photo_objet_monitoring_policies policy
  JOIN public.restaurants store ON store.id = policy.store_id
  WHERE policy.effective_to IS NULL
    AND policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND store.is_active = true;
  IF v_open_v4 <> 6 THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_REQUIRES_SIX_ACTIVE_V4_STORES: %', v_open_v4;
  END IF;
END
$preflight$;

SELECT 'Photo Objet precise start/report ready preflight passed' AS result;
