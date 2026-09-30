-- Known source identities, counts, and test-store guard. No mutations.
DO $$ BEGIN
  IF (SELECT count(*) FROM pg_trigger WHERE
       (tgrelid='public.inventory_receipts'::regclass AND tgname='inventory_receipt_header_change_guard' OR
        tgrelid='public.inventory_receipt_lines'::regclass AND tgname='inventory_receipt_line_change_guard')
       AND NOT tgisinternal AND tgenabled='O')<>2 THEN
    RAISE EXCEPTION 'BUNSIK_RECEIPT_GUARDS_NOT_ENABLED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878') OR
     NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878' AND lower(name) LIKE '%sample%') THEN
    RAISE EXCEPTION 'BUNSIK_STORE_SCOPE_CHANGED';
  END IF;
  IF (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c')<>104 OR
     (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a')<>104 THEN
    RAISE EXCEPTION 'BUNSIK_SOURCE_COUNTS_CHANGED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.procurement_quote_lines q JOIN public.inventory_supplier_items s ON s.id=q.supplier_item_id JOIN public.inventory_products p ON p.id=s.product_id WHERE p.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') OR
     EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE p.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') THEN
    RAISE EXCEPTION 'BUNSIK_SAMPLE_UNEXPECTED_PROCUREMENT_DEPENDENCY';
  END IF;
END $$;
