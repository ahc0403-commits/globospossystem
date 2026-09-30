-- Run only before new sample purchases/stocktakes. Never discard post-release work.
BEGIN;
SET LOCAL lock_timeout='5s';
LOCK TABLE public.inventory_products,public.inventory_items,public.inventory_supplier_items,public.inventory_purchase_orders,public.inventory_receipts IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.inventory_purchase_orders WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') OR EXISTS(SELECT 1 FROM public.inventory_stock_audit_sessions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') OR EXISTS(SELECT 1 FROM public.inventory_transactions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') THEN RAISE EXCEPTION 'BUNSIK_ROLLBACK_NEW_SAMPLE_ACTIVITY'; END IF;
END $$;
DELETE FROM public.inventory_supplier_items WHERE product_id IN(SELECT id FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_items'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_items(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_items,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_items''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_products'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_products(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_products,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_products''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_transactions'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_transactions(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_transactions,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_transactions''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_physical_counts'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_physical_counts(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_physical_counts,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_physical_counts''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.menu_recipes'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.menu_recipes(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.menu_recipes,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''menu_recipes''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_supplier_items'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_supplier_items(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_supplier_items,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_supplier_items''))',cols,cols);
END $$;
DELETE FROM public.inventory_supplier_item_price_history WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_supplier_item_price_history'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_supplier_item_price_history(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_supplier_item_price_history,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_supplier_item_price_history''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_daily_consumption'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_daily_consumption(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_daily_consumption,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_daily_consumption''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_recommendation_runs'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_recommendation_runs(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_recommendation_runs,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_recommendation_runs''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_recommendation_lines'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_recommendation_lines(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_recommendation_lines,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_recommendation_lines''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_stock_audit_sessions'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_stock_audit_sessions(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_stock_audit_sessions,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_stock_audit_sessions''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_stock_audit_lines'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_stock_audit_lines(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_stock_audit_lines,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_stock_audit_lines''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_purchase_orders'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_purchase_orders(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_purchase_orders,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_purchase_orders''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_purchase_documents'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_purchase_documents(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_purchase_documents,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_purchase_documents''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_purchase_approval_events'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_purchase_approval_events(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_purchase_approval_events,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_purchase_approval_events''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_purchase_order_lines'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_purchase_order_lines(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_purchase_order_lines,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_purchase_order_lines''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipts'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipts(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipts,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipts''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipt_lines'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipt_lines(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipt_lines,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipt_lines''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipt_confirmation_attempts'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipt_confirmation_attempts(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipt_confirmation_attempts,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipt_confirmation_attempts''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipt_submission_attempts'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipt_submission_attempts(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipt_submission_attempts,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipt_submission_attempts''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipt_change_history'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipt_change_history(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipt_change_history,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipt_change_history''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_receipt_issues'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_receipt_issues(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_receipt_issues,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_receipt_issues''))',cols,cols);
END $$;
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid='public.inventory_supplier_returns'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';
 EXECUTE format('INSERT INTO public.inventory_supplier_returns(%s) SELECT %s FROM jsonb_populate_recordset(NULL::public.inventory_supplier_returns,(SELECT rows FROM inventory_migration_backup.bunsik_20260930 WHERE table_name=''inventory_supplier_returns''))',cols,cols);
END $$;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.inventory_transactions t JOIN inventory_migration_backup.bunsik_20260930 z ON z.table_name='new_binh_ids' CROSS JOIN LATERAL jsonb_array_elements(z.rows) n WHERE t.ingredient_id=(n->>'item_id')::uuid) THEN RAISE EXCEPTION 'BUNSIK_ROLLBACK_NEW_BINH_STOCK_ACTIVITY'; END IF;
END $$;
DELETE FROM public.inventory_supplier_items WHERE product_id IN (SELECT (n->>'product_id')::uuid FROM inventory_migration_backup.bunsik_20260930 z CROSS JOIN LATERAL jsonb_array_elements(z.rows)n WHERE table_name='new_binh_ids');
DELETE FROM public.inventory_products WHERE id IN (SELECT (n->>'product_id')::uuid FROM inventory_migration_backup.bunsik_20260930 z CROSS JOIN LATERAL jsonb_array_elements(z.rows)n WHERE table_name='new_binh_ids');
DELETE FROM public.inventory_items WHERE id IN (SELECT (n->>'item_id')::uuid FROM inventory_migration_backup.bunsik_20260930 z CROSS JOIN LATERAL jsonb_array_elements(z.rows)n WHERE table_name='new_binh_ids');
UPDATE public.inventory_products p SET product_code=old.product_code,updated_at=now() FROM inventory_migration_backup.bunsik_20260930 z CROSS JOIN LATERAL jsonb_populate_recordset(NULL::public.inventory_products,z.rows) old WHERE z.table_name='binh_products' AND p.id=old.id;
COMMIT;
