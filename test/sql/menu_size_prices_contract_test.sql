\set ON_ERROR_STOP on
BEGIN;
SET request.jwt.claim.sub='93000000-0000-4000-8000-000000000099';
DO $$
DECLARE store uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; m public.menu_items; child public.menu_items; old_key text; old_other jsonb;
BEGIN
 m:=public.admin_create_menu_item_with_options(store,NULL,'탕수육','Thịt','Pork',NULL,190000,'{"size_prices":{"S":190000,"L":370000}}');
 SELECT * INTO STRICT child FROM public.menu_items WHERE size_parent_id=m.id;
 ASSERT (SELECT count(*)=1 FROM public.menu_items WHERE size_parent_id IS NULL);
 ASSERT m.size_prices='{"S":190000,"L":370000}'::jsonb AND m.price=190000 AND child.price=370000;
 ASSERT (m.menu_option_key::jsonb)->4->>'menu_id'=m.id::text;
 ASSERT (child.menu_option_key::jsonb)->4->>'menu_id'=m.id::text;
 ASSERT (child.menu_option_key::jsonb)->4->'names'->>'name_ko'='탕수육';
 INSERT INTO public.menu_items(restaurant_id,name,price) VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c','Other store',10000);
 SELECT to_jsonb(i) INTO old_other FROM public.menu_items i WHERE name='Other store';
 old_key:=child.menu_option_key;
 m:=public.admin_update_menu_item_with_options(m.id,'새 탕수육','Thịt mới','New pork',NULL,210000,'{"size_prices":{"S":210000,"L":390000},"spice_level":"spicy"}');
 SELECT * INTO child FROM public.menu_items WHERE id=child.id;
 ASSERT child.price=390000 AND child.name_en='L · 🌶 Spicy dish · New pork' AND child.menu_option_key<>old_key;
 UPDATE public.menu_items SET is_visible_public=true WHERE id=m.id;
 ASSERT (SELECT is_visible_public FROM public.menu_items WHERE id=child.id);
 BEGIN
  PERFORM public.admin_update_menu_item_with_options(m.id,'invalid','invalid','invalid',NULL,1,'{"size_prices":{"S":1,"L":0}}');
  RAISE EXCEPTION 'INVALID_PRICE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_ITEM_PRICE_INVALID',SQLERRM; END;
 ASSERT (SELECT size_prices='{"S":210000,"L":390000}'::jsonb FROM public.menu_items WHERE id=m.id);
 BEGIN
  UPDATE public.menu_items SET price=1 WHERE id=child.id;
  RAISE EXCEPTION 'CHILD_PRICE_TAMPER_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_SIZE_PRICE_MANAGED_BY_PARENT',SQLERRM; END;
 BEGIN
  UPDATE public.menu_items SET restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' WHERE id=child.id;
  RAISE EXCEPTION 'CROSS_STORE_PARENT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM<>'CROSS_STORE_PARENT_ACCEPTED'; END;
 ASSERT (SELECT to_jsonb(i)=old_other FROM public.menu_items i WHERE name='Other store');
 m:=public.admin_update_menu_item_with_options(m.id,'탕수육','Thịt','Pork',NULL,220000,'{"size_prices":{}}');
 ASSERT m.price=220000 AND m.portion_code='';
 ASSERT (SELECT is_archived AND NOT is_available FROM public.menu_items WHERE id=child.id);
 ASSERT NOT has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE');
END $$;
ROLLBACK;
SELECT 'MENU_SIZE_PRICES_CONTRACT=PASS';
