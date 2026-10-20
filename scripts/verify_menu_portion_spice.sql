DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='menu_option_key' AND is_generated='ALWAYS')
 OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='order_items' AND column_name='menu_option_snapshot')
 OR has_function_privilege('anon','public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.validate_menu_option_batch(uuid,jsonb,text)','EXECUTE') THEN RAISE EXCEPTION 'MENU_OPTION_VERIFICATION_FAILED'; END IF;
END $$;
SELECT 'MENU_PORTION_SPICE_VERIFY=PASS';
