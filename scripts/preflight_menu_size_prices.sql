DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='size_prices')
 OR to_regprocedure('public.menu_registered_option_key(text,text,text,numeric)') IS NULL THEN RAISE EXCEPTION 'MENU_SIZE_PREREQUISITES_CHANGED'; END IF;
END $$;
SELECT 'MENU_SIZE_PRICES_PREFLIGHT=PASS';
