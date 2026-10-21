DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='meal_choices')
 OR has_function_privilege('anon','public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE')
 OR EXISTS(SELECT 1 FROM public.menu_items p WHERE p.size_parent_id IS NULL AND p.meal_choices AND NOT p.is_archived AND NOT EXISTS
  (SELECT 1 FROM public.menu_items c WHERE c.size_parent_id=p.id AND c.meal_choice='rice' AND c.portion_code=p.portion_code AND NOT c.is_archived))
 THEN RAISE EXCEPTION 'MENU_MEAL_CHOICES_VERIFY_FAILED'; END IF;
END $$;
SELECT 'MENU_MEAL_CHOICES_VERIFY=PASS';
