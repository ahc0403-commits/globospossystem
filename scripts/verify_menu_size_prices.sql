DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='size_prices')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='menu_size_sync_batch' AND NOT tgisinternal)
 OR has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'MENU_SIZE_PRICES_VERIFY_FAILED'; END IF;
END $$;
SELECT 'MENU_SIZE_PRICES_VERIFY=PASS';
