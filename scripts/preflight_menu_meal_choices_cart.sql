DO $$ BEGIN
 IF to_regprocedure('public.menu_size_price_sync_batch()') IS NULL
 OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='meal_choices')
 THEN RAISE EXCEPTION 'MENU_MEAL_CHOICES_PREREQUISITES_CHANGED'; END IF;
END $$;
SELECT 'MENU_MEAL_CHOICES_PREFLIGHT=PASS';
