-- Read-only production prerequisites; no operational records are changed.
DO $preflight$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['users','brands','brand_master','companies',
    'tax_entity','tax_entity_brands','restaurants','audit_logs'] LOOP
    IF to_regclass('public.' || v_table) IS NULL THEN
      RAISE EXCEPTION 'BRAND_PREFLIGHT_TABLE_MISSING:%', v_table;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT FROM pg_class WHERE oid='public.restaurants'::regclass AND relkind IN ('r','p')) THEN
    RAISE EXCEPTION 'BRAND_PREFLIGHT_RESTAURANTS_MUST_REMAIN_PHYSICAL';
  END IF;
  IF NOT EXISTS (SELECT FROM public.brand_master g JOIN public.companies c ON c.id=g.company_id) THEN
    RAISE EXCEPTION 'BRAND_PREFLIGHT_ORGANIZATION_GROUP_REQUIRED';
  END IF;
  IF NOT EXISTS (SELECT FROM public.users WHERE role='super_admin' AND is_active AND auth_id IS NOT NULL) THEN
    RAISE EXCEPTION 'BRAND_PREFLIGHT_ACTIVE_MASTER_REQUIRED';
  END IF;
  IF to_regprocedure('auth.uid()') IS NULL
    OR to_regprocedure('public.admin_create_restaurant_v2(text,text,text,uuid,uuid,text,numeric,uuid)') IS NULL THEN
    RAISE EXCEPTION 'BRAND_PREFLIGHT_HIERARCHY_RPC_MISSING';
  END IF;
  IF EXISTS (
    SELECT FROM (VALUES ('id'),('name'),('address'),('is_active'),('brand_id'),('tax_entity_id')) required(name)
    WHERE NOT EXISTS (SELECT FROM information_schema.columns c WHERE c.table_schema='public'
      AND c.table_name='restaurants' AND c.column_name=required.name)
  ) THEN RAISE EXCEPTION 'BRAND_PREFLIGHT_OFFICE_CONTRACT_MISSING'; END IF;
END;
$preflight$;
SELECT 'BRAND_PREFLIGHT_PASS' AS result,
  (SELECT count(*) FROM public.brands) AS brands,
  (SELECT count(*) FROM public.restaurants) AS stores,
  (SELECT count(*) FROM public.brand_master) AS organization_groups;
