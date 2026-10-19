BEGIN;

-- production-gate: self-verifying
-- Exclude the existing non-fiscal SAMPLE store and entity from declarations.
-- Patch only read predicates so historical payments and current VAT snapshots
-- remain intact, including tax-line changes applied after the original RPC.
DO $migration$
DECLARE
  v_rpc regprocedure :=
    'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_definition text := pg_get_functiondef(v_rpc);
  v_old_paid constant text := $old$    WHERE payment.is_revenue = true
    GROUP BY payment.order_id, payment.restaurant_id$old$;
  v_new_paid constant text := $new$    WHERE payment.is_revenue = true
      AND restaurant.id <> v_sample_store_id
      AND restaurant.tax_entity_id IS DISTINCT FROM v_sample_entity_id
    GROUP BY payment.order_id, payment.restaurant_id$new$;
  v_old_seller constant text := $old$    ) order_lines ON true
  ),
  entity_rollups AS ($old$;
  v_new_seller constant text := $new$    ) order_lines ON true
    WHERE seller.id <> v_sample_entity_id
  ),
  entity_rollups AS ($new$;
BEGIN
  IF position(v_new_paid IN v_definition) > 0
     AND position(v_new_seller IN v_definition) > 0 THEN
    RETURN;
  END IF;
  IF (length(v_definition) - length(replace(v_definition, v_old_paid, '')))
       / length(v_old_paid) <> 1
     OR (length(v_definition) - length(replace(v_definition, v_old_seller, '')))
       / length(v_old_seller) <> 1 THEN
    RAISE EXCEPTION 'RESTAURANT_REPORT_SAMPLE_EXCLUSION_ANCHOR_CHANGED';
  END IF;
  EXECUTE replace(
    replace(v_definition, v_old_paid, v_new_paid),
    v_old_seller, v_new_seller
  );
END;
$migration$;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_exports_by_tax_entity(date) IS
  'Super-admin MISA declaration grouped by seller entity. Non-fiscal SAMPLE store/entity sales are excluded. Available throughout the selected HCM day; confirmed integrity failures fail closed.';

DO $verification$
DECLARE
  v_rpc regprocedure :=
    'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_definition text := pg_get_functiondef(v_rpc);
BEGIN
  IF position('AND restaurant.id <> v_sample_store_id' IN v_definition) = 0
     OR position('AND restaurant.tax_entity_id IS DISTINCT FROM v_sample_entity_id' IN v_definition) = 0
     OR position('WHERE seller.id <> v_sample_entity_id' IN v_definition) = 0
     OR position('IF p_business_date > v_hcm_now::date THEN' IN v_definition) = 0
     OR position('v_finalization.status' IN v_definition) = 0
     OR position('is_super_admin()' IN v_definition) = 0
     OR position('''item_type'', item.item_type' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_rpc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_rpc, 'EXECUTE') THEN
    RAISE EXCEPTION 'RESTAURANT_REPORT_SAMPLE_EXCLUSION_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
