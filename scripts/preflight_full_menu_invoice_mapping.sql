-- Read-only production compatibility checks. A failed precondition stops the
-- official deployment before any migration is applied.
DO $$ BEGIN
 IF to_regprocedure('public.admin_import_menu_items_before_beverage_tax(uuid,jsonb)') IS NULL
 OR to_regprocedure('public.admin_update_menu_workbook_i18n_apply(uuid,jsonb,jsonb)') IS NULL
 OR to_regprocedure('public.approve_invoice_mapping_batch(uuid,uuid,jsonb)') IS NULL
 OR to_regprocedure('public.revalidate_meinvoice_export_snapshots(date,uuid,uuid[])') IS NULL THEN
  RAISE EXCEPTION 'FULL_MENU_MAPPING_PRECONDITION_MISSING';
 END IF;
 IF EXISTS(SELECT 1 FROM public.menu_invoice_profiles a JOIN public.menu_invoice_profiles b ON a.menu_item_id=b.menu_item_id AND a.id<b.id
  AND tstzrange(a.effective_from,a.effective_to,'[)') && tstzrange(b.effective_from,b.effective_to,'[)'))
 OR EXISTS(SELECT 1 FROM public.item_type_invoice_profiles a JOIN public.item_type_invoice_profiles b ON a.store_id=b.store_id AND a.tax_entity_id=b.tax_entity_id AND a.item_type=b.item_type AND a.id<b.id
  AND tstzrange(a.effective_from,a.effective_to,'[)') && tstzrange(b.effective_from,b.effective_to,'[)')) THEN
  RAISE EXCEPTION 'FULL_MENU_MAPPING_EXISTING_PERIOD_OVERLAP';
 END IF;
END $$;
SELECT 'FULL_MENU_MAPPING_PREFLIGHT=PASS';
