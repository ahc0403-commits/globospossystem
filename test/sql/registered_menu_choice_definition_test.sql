-- Minimal fixture checks pure normalization and atomic legacy projection inheritance.
-- The full-schema registered_menu_choices_test.sql covers actual ACLs and orders.
BEGIN;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
DO $$ DECLARE m public.menu_items; definition jsonb; chosen text; snap jsonb; ids uuid[];
BEGIN
 definition:='{"schema_version":1,"groups":[{"id":"spice","name_ko":"맵기","name_vi":"Độ cay","name_en":"Spice","min":1,"max":1,"repeat":false,"channels":["pos","qr","direct"],"values":[{"id":"mild","name_ko":"안맵게","name_vi":"Không cay","name_en":"Mild","price_delta":0,"available":true},{"id":"hot","name_ko":"맵게","name_vi":"Cay","name_en":"Hot","price_delta":2000,"available":true}]}]}';
 ASSERT public.menu_choice_definition_valid(definition);
 ASSERT NOT public.menu_choice_definition_valid(definition-'schema_version');
 ASSERT NOT public.menu_choice_definition_valid(jsonb_set(definition,'{groups,0,values,0,id}','"hot"'));
 m:=public.admin_create_menu_item_with_options('273b057e-3b69-46e3-93c1-6194c2802849',NULL,'테스트','Thử','Test',NULL,10000,
  jsonb_build_object('size_prices','{"S":10000,"L":18000}'::jsonb,'choice_definition',definition),0,true,NULL,NULL);
 ASSERT (SELECT count(*)=1 FROM menu_items WHERE size_parent_id=m.id AND choice_definition=definition);
 SELECT array_agg(id ORDER BY id) INTO ids FROM menu_items WHERE id=m.id OR size_parent_id=m.id;
 chosen:=jsonb_build_object('schema',2,'revision',md5(m.menu_option_key),'selected',jsonb_build_array(jsonb_build_object('value_id','hot','quantity',1)))::text;
 snap:=public.menu_choice_snapshot(to_jsonb(m),chosen,'qr');
 ASSERT (snap->>'unit_price')::numeric=12000;
 ASSERT snap->>'name_vi' LIKE '%Cay%';
 -- An old registration caller omits the new definition and still preserves it.
 m:=public.admin_update_menu_item_with_options(m.id,'테스트','Thử','Test',NULL,10000,'{"size_prices":{"S":10000,"L":18000}}',NULL);
 ASSERT m.choice_definition=definition;
 ASSERT (SELECT array_agg(id ORDER BY id)=ids FROM menu_items WHERE id=m.id OR size_parent_id=m.id);
 -- New noodle/rice children inherit in the statement trigger, including Excel paths.
 UPDATE menu_items SET meal_choices=true WHERE id=m.id;
 ASSERT (SELECT count(*)=4 AND bool_and(choice_definition=definition) FROM menu_items WHERE id=m.id OR size_parent_id=m.id);
 BEGIN PERFORM public.menu_choice_snapshot(to_jsonb(m),NULL,'qr'); RAISE EXCEPTION 'REQUIRED_CHOICE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'MENU_SELECTION_%' THEN RAISE; END IF; END;
 BEGIN PERFORM public.menu_choice_snapshot(to_jsonb(m),jsonb_set(chosen::jsonb,'{revision}','"stale"')::text,'qr'); RAISE EXCEPTION 'STALE_CHOICE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'MENU_SELECTION_CHANGED' THEN RAISE; END IF; END;
END $$;
SELECT 'REGISTERED_CHOICE_DEFINITION=PASS';
ROLLBACK;
