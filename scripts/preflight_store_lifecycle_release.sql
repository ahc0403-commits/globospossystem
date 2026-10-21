-- Read-only production gate; no synthetic business transactions.
DO $preflight$
BEGIN
 IF to_regclass('public.store_operating_profiles') IS NOT NULL
 OR to_regclass('public.store_lifecycle') IS NOT NULL THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_ALREADY_OR_PARTLY_APPLIED';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations WHERE version='20261021230000') THEN
  RAISE EXCEPTION 'LIFECYCLE_OWNER_SALES_PREREQUISITE_MISSING';
 END IF;
 IF (SELECT count(*) FROM public.restaurants WHERE id IN('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c') AND is_active)<>2 THEN
  RAISE EXCEPTION 'LIFECYCLE_LEGACY_STORES_NOT_ACTIVE';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND kds_workflow='kitchen_floor')
 OR NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND kds_workflow='kitchen_tray_floor')
 OR EXISTS(SELECT 1 FROM public.users WHERE fixed_account_code='jgbt_tray1' AND is_active) THEN
  RAISE EXCEPTION 'LIFECYCLE_LEGACY_WORKFLOW_DRIFT';
 END IF;
END $preflight$;
SELECT 'LIFECYCLE_RELEASE_PREFLIGHT=PASS' AS result;
