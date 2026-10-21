\set ON_ERROR_STOP on
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
CREATE TABLE public.order_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,menu_item_id uuid,unit_price numeric,
 quantity int DEFAULT 1,is_service_item boolean DEFAULT false,menu_option_snapshot jsonb DEFAULT '{}',label text,display_name text,combo_components jsonb DEFAULT '[]');
CREATE TABLE public.direct_order_request_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid,restaurant_id uuid,menu_item_id uuid,unit_price numeric,
 name_ko text,name_vi text,name_en text,display_name text,menu_option_snapshot jsonb DEFAULT '{}',combo_components jsonb DEFAULT '[]');
CREATE TRIGGER menu_option_capture_batch AFTER INSERT ON public.order_items REFERENCING NEW TABLE AS new_menu_lines FOR EACH STATEMENT EXECUTE FUNCTION public.capture_menu_option_batch();
CREATE TRIGGER menu_option_capture_batch AFTER INSERT ON public.direct_order_request_items REFERENCING NEW TABLE AS new_menu_lines FOR EACH STATEMENT EXECUTE FUNCTION public.capture_menu_option_batch();
DO $$
DECLARE m public.menu_items; rice_id uuid; frozen jsonb; old_key text;
BEGIN
 m:=public.admin_create_menu_item_with_options('273b057e-3b69-46e3-93c1-6194c2802849',null,'짬뽕','Jjamppong','Jjamppong','Jjamppong',100,
  '{"meal_choices":true,"size_prices":{"S":100,"L":200}}');
 IF m.meal_choice<>'noodles' OR (SELECT count(*) FROM public.menu_items WHERE id=m.id OR size_parent_id=m.id)<>4 THEN RAISE EXCEPTION 'FOUR_COMBINATIONS_REQUIRED'; END IF;
 IF (SELECT count(DISTINCT menu_option_key) FROM public.menu_items WHERE id=m.id OR size_parent_id=m.id)<>4 THEN RAISE EXCEPTION 'CHOICE_KEYS_COLLIDED'; END IF;
 SELECT id,menu_option_key INTO rice_id,old_key FROM public.menu_items WHERE size_parent_id=m.id AND portion_code='S' AND meal_choice='rice';
 BEGIN
  PERFORM public.validate_menu_option_batch(m.restaurant_id,jsonb_build_array(jsonb_build_object('menu_item_id',rice_id)),'qr');
  RAISE EXCEPTION 'MISSING_CHOICE_VERSION_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'QR_MENU_ITEM_UNAVAILABLE' THEN RAISE; END IF; END;
 PERFORM public.validate_menu_option_batch(m.restaurant_id,jsonb_build_array(jsonb_build_object('menu_item_id',rice_id,'menu_option_key',old_key)),'qr');
 INSERT INTO public.order_items(restaurant_id,menu_item_id,unit_price)
 SELECT restaurant_id,id,price FROM public.menu_items WHERE id=m.id OR size_parent_id=m.id;
 IF (SELECT count(*) FROM public.order_items WHERE menu_option_snapshot->>'meal_choice' IN ('rice','noodles'))<>4 THEN RAISE EXCEPTION 'SNAPSHOT_LOST'; END IF;
 SELECT menu_option_snapshot INTO frozen FROM public.order_items WHERE menu_item_id=rice_id;
 IF frozen->>'name_ko' NOT LIKE '밥%' THEN RAISE EXCEPTION 'KITCHEN_MEAL_LABEL_LOST'; END IF;
 m:=public.admin_update_menu_item_with_options(m.id,'짬뽕','Jjamppong','Jjamppong','Jjamppong',100,'{"meal_choices":true,"size_prices":{"S":110,"L":220}}');
 IF (SELECT menu_option_snapshot FROM public.order_items WHERE menu_item_id=rice_id)<>frozen THEN RAISE EXCEPTION 'HISTORY_CHANGED'; END IF;
 IF (SELECT price FROM public.menu_items WHERE id=rice_id)<>110 THEN RAISE EXCEPTION 'CHOICE_REPRICE_LOST'; END IF;
 BEGIN
  PERFORM public.validate_menu_option_batch(m.restaurant_id,jsonb_build_array(jsonb_build_object('menu_item_id',rice_id,'menu_option_key',old_key)),'qr');
  RAISE EXCEPTION 'STALE_CHOICE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'QR_MENU_ITEM_UNAVAILABLE' THEN RAISE; END IF; END;
 m:=public.admin_update_menu_item_with_options(m.id,'짬뽕','Jjamppong','Jjamppong','Jjamppong',110,'{"meal_choices":false,"size_prices":{"S":110,"L":220}}');
 IF NOT (SELECT is_archived FROM public.menu_items WHERE id=rice_id) THEN RAISE EXCEPTION 'DISABLED_RICE_SELLABLE'; END IF;
 m:=public.admin_update_menu_item_with_options(m.id,'짬뽕','Jjamppong','Jjamppong','Jjamppong',110,'{"meal_choices":true,"size_prices":{"S":110,"L":220}}');
 IF (SELECT is_archived FROM public.menu_items WHERE id=rice_id) THEN RAISE EXCEPTION 'REENABLE_LOST_ID'; END IF;
 IF has_function_privilege('anon','public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text)','EXECUTE') THEN RAISE EXCEPTION 'ANON_ADMIN_ACCESS'; END IF;
 -- A single-size dish also requires an explicit noodles/rice choice.
 m:=public.admin_create_menu_item_with_options(m.restaurant_id,null,'단일 짬뽕','Món','Dish','Món',150,'{"meal_choices":true}');
 IF (SELECT count(*) FROM public.menu_items WHERE size_parent_id=m.id)<>1 OR m.menu_option_key IS NULL THEN RAISE EXCEPTION 'SINGLE_SIZE_MEAL_CHOICES_MISSING'; END IF;
END $$;
-- Set-based scale probe: the trigger handles all changed menus in the batch.
INSERT INTO public.menu_items(restaurant_id,name,name_ko,name_vi,name_en,price,meal_choices)
 SELECT '273b057e-3b69-46e3-93c1-6194c2802849', 'Scale '||n,'Scale '||n,'Scale '||n,'Scale '||n,100,true FROM generate_series(1,500)n;
EXPLAIN(ANALYZE,BUFFERS) UPDATE public.menu_items SET description='Batch menu change' WHERE size_parent_id IS NULL AND name_en LIKE '%Scale%';
SELECT 'MENU_MEAL_CHOICES_CART_SQL=PASS';
