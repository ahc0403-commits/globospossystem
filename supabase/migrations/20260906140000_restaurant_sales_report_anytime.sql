BEGIN;

-- production-gate: self-verifying
-- Remove the reporting clock gate without changing receipt aggregation, VAT
-- snapshots, authorization, or the independent Restaurant cutoff/audit jobs.
DO $migration$
DECLARE
  v_rpc regprocedure := 'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_definition text;
  v_old constant text := $old$  v_report_ready_at := (p_business_date + TIME '22:00:00')
    AT TIME ZONE 'Asia/Ho_Chi_Minh';

  IF p_business_date > v_hcm_now::date
     OR (
       p_business_date = v_hcm_now::date
       AND v_hcm_now::time < TIME '22:00:00'
     ) THEN$old$;
  v_new constant text := $new$  v_report_ready_at := p_business_date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh';

  IF p_business_date > v_hcm_now::date THEN$new$;
BEGIN
  SELECT pg_get_functiondef(v_rpc) INTO v_definition;
  IF (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'RESTAURANT_REPORT_ANYTIME_ANCHOR_CHANGED';
  END IF;
  EXECUTE replace(v_definition, v_old, v_new);
END;
$migration$;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_exports_by_tax_entity(date) IS
  'Super-admin MISA export available throughout the selected HCM day. Missing audit finalization does not block reporting; confirmed integrity failures still fail closed. Refresh to include later payments.';
COMMENT ON FUNCTION public.get_restaurant_daily_sales_export(date) IS
  'Legacy single-entity MISA export with the same anytime availability as the grouped endpoint.';

DO $verification$
DECLARE
  v_rpc regprocedure := 'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_definition text := pg_get_functiondef(v_rpc);
BEGIN
  IF position('22:00' IN v_definition) > 0
     OR position('22:20' IN v_definition) > 0
     OR position('v_hcm_now::time' IN v_definition) > 0
     OR position('IF p_business_date > v_hcm_now::date THEN' IN v_definition) = 0
     OR position('v_finalization.status' IN v_definition) = 0
     OR position('is_super_admin()' IN v_definition) = 0
     OR position('''item_type'', item.item_type' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_rpc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_rpc, 'EXECUTE') THEN
    RAISE EXCEPTION 'RESTAURANT_REPORT_ANYTIME_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
