DO $$ BEGIN
 IF to_regprocedure('public.admin_move_menu_item(uuid,uuid,uuid,text)') IS NULL
 OR has_function_privilege('anon','public.admin_move_menu_item(uuid,uuid,uuid,text)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.admin_move_menu_item(uuid,uuid,uuid,text)','EXECUTE')
 OR position('require_admin_actor_for_restaurant' IN pg_get_functiondef('public.admin_move_menu_item(uuid,uuid,uuid,text)'::regprocedure))=0
 THEN RAISE EXCEPTION 'ADMIN_MENU_ITEM_ORDER_VERIFY_FAILED'; END IF;
END $$;
SELECT 'ADMIN_MENU_ITEM_ORDER_VERIFY=PASS';
