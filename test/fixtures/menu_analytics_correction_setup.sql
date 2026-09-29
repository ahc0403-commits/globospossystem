INSERT INTO public.restaurants(id,name,brand_id) VALUES
  ('8bc9eef5-dcd5-46b1-b931-23f77132322c','Binh Thanh',
   'b1000000-0000-4000-8000-000000000004');
INSERT INTO public.users(id,auth_id,brand_id,role,full_name) VALUES
  ('b1000000-0000-4000-8000-0000000000b1',
   'b1000000-0000-4000-8000-0000000000a1',
   'b1000000-0000-4000-8000-000000000004','brand_admin','BM');
INSERT INTO public.menu_categories(id,restaurant_id,name,name_ko,name_vi,name_en) VALUES
  ('f4a29074-33b8-4b46-9055-5b37b9d11650',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c','음료','음료','Đồ uống','Drinks');
INSERT INTO public.menu_items(id,restaurant_id,category_id,name,name_ko,name_vi,name_en,price) VALUES
  ('53249604-fd2e-40f5-a776-3e1bc5f32153',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   'f4a29074-33b8-4b46-9055-5b37b9d11650','코카콜라 일반','코카콜라 일반','Coca-Cola','Coca-Cola',10000),
  ('1917ec7d-c11e-4ed6-aced-c679d2104fba',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   'f4a29074-33b8-4b46-9055-5b37b9d11650','코카코라 제로','코카코라 제로','Coca-Cola Zero','Coca-Cola Zero',10000),
  ('4eda734f-4ac9-4f05-9eeb-0a4e4b122988',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   'f4a29074-33b8-4b46-9055-5b37b9d11650','Sting','Sting','Sting','Sting',15000),
  ('8ce1a136-f51a-4ee6-a14e-73184a874646',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   'f4a29074-33b8-4b46-9055-5b37b9d11650','환다 오렌지','환다 오렌지','Fanta Cam','Fanta Orange',12000);
INSERT INTO public.orders(id,restaurant_id,status) VALUES
  ('00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','completed'),
  ('00000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c','completed'),
  ('00000000-0000-4000-8000-000000000003','8bc9eef5-dcd5-46b1-b931-23f77132322c','completed');
INSERT INTO public.order_items(id,restaurant_id,order_id,menu_item_id,menu_item_id_snapshot,label,display_name,quantity,unit_price,status,paying_amount_inc_tax,created_at) VALUES
  ('00000000-0000-4000-8000-000000000011','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000001','53249604-fd2e-40f5-a776-3e1bc5f32153','53249604-fd2e-40f5-a776-3e1bc5f32153','코카콜라 일반','코카콜라 일반',2,10000,'served',20000,'2026-09-15 10:00Z'),
  ('00000000-0000-4000-8000-000000000012','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000001','1917ec7d-c11e-4ed6-aced-c679d2104fba','1917ec7d-c11e-4ed6-aced-c679d2104fba','코카코라 제로','코카코라 제로',1,10000,'served',10000,'2026-09-15 10:01Z'),
  ('00000000-0000-4000-8000-000000000013','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000002','4eda734f-4ac9-4f05-9eeb-0a4e4b122988','4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Sting','Sting',1,15000,'served',15000,'2026-09-15 10:02Z'),
  ('00000000-0000-4000-8000-000000000014','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000002','8ce1a136-f51a-4ee6-a14e-73184a874646','8ce1a136-f51a-4ee6-a14e-73184a874646','환다 오렌지','환다 오렌지',1,12000,'served',12000,'2026-09-15 10:03Z'),
  ('00000000-0000-4000-8000-000000000015','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000003','53249604-fd2e-40f5-a776-3e1bc5f32153','53249604-fd2e-40f5-a776-3e1bc5f32153','코카콜라 일반','코카콜라 일반',1,10000,'served',10000,'2026-09-29 10:00Z');
INSERT INTO public.payments(id,order_id,restaurant_id,amount,method,created_at) VALUES
  ('00000000-0000-4000-8000-000000000021','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c',30000,'CASH','2026-09-15 10:05Z'),
  ('00000000-0000-4000-8000-000000000022','00000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c',27000,'CASH','2026-09-15 10:06Z'),
  ('00000000-0000-4000-8000-000000000023','00000000-0000-4000-8000-000000000003','8bc9eef5-dcd5-46b1-b931-23f77132322c',10000,'CASH','2026-09-29 10:05Z');

-- Minimal category mutations; the production RPCs additionally audit names.
CREATE FUNCTION public.admin_create_menu_category_i18n(
  p_store_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_sort_order integer
) RETURNS public.menu_categories LANGUAGE plpgsql AS $function$
DECLARE category public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  INSERT INTO public.menu_categories(id,restaurant_id,name,name_ko,name_vi,name_en)
  VALUES (gen_random_uuid(),p_store_id,p_name_ko,p_name_ko,p_name_vi,p_name_en)
  RETURNING * INTO category;
  RETURN category;
END $function$;

CREATE FUNCTION public.admin_update_menu_category_i18n(
  p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text
) RETURNS public.menu_categories LANGUAGE plpgsql AS $function$
DECLARE category public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(
    (SELECT restaurant_id FROM public.menu_categories WHERE id=p_category_id));
  UPDATE public.menu_categories SET name=p_name_ko,name_ko=p_name_ko,
    name_vi=p_name_vi,name_en=p_name_en WHERE id=p_category_id
  RETURNING * INTO category;
  RETURN category;
END $function$;

CREATE TABLE public.emergency_order_queue(
  id uuid, session_id uuid, order_id uuid, restaurant_id uuid, created_at timestamptz,
  queue_no text, table_number text, physical_floor_label text, floor_label text,
  physical_floor_inferred boolean
);
ALTER TABLE public.tables ADD COLUMN floor_label text;
CREATE TABLE public.emergency_fulfillment_sessions(id uuid, status text);
CREATE TABLE public.emergency_fulfillment_items(
  id uuid, restaurant_id uuid, session_id uuid, order_id uuid, order_item_id uuid,
  ordered_quantity integer, kitchen_done_quantity integer,
  tray_dispatched_quantity integer, floor_served_quantity integer,
  is_cancelled boolean
);
CREATE TABLE public.emergency_floor_direct_items(
  id uuid, restaurant_id uuid, session_id uuid, order_id uuid, order_item_id uuid,
  component_menu_item_id uuid, name_ko text, name_vi text, name_en text,
  ordered_quantity integer, floor_served_quantity integer, is_cancelled boolean
);
CREATE TABLE public.emergency_combo_component_items(
  id uuid, restaurant_id uuid, session_id uuid, order_id uuid, order_item_id uuid,
  component_menu_item_id uuid, name_ko text, name_vi text, name_en text,
  ordered_quantity integer, kitchen_done_quantity integer,
  tray_dispatched_quantity integer, floor_served_quantity integer,
  is_cancelled boolean
);
CREATE TABLE public.emergency_fulfillment_events(
  session_id uuid, order_id uuid, restaurant_id uuid, order_item_id uuid,
  floor_direct_item_id uuid, combo_component_item_id uuid,
  stage text, delta integer, created_at timestamptz
);

INSERT INTO public.emergency_fulfillment_sessions(id,status) VALUES
  ('00000000-0000-4000-8000-000000000031','completed');
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at) VALUES
  ('00000000-0000-4000-8000-000000000041','00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 10:00Z'),
  ('00000000-0000-4000-8000-000000000042','00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 10:02Z');
INSERT INTO public.emergency_fulfillment_items(id,restaurant_id,session_id,order_id,order_item_id,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity,floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000051','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000011',2,2,2,2,false),
  ('00000000-0000-4000-8000-000000000052','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000012',1,1,1,1,false);
INSERT INTO public.emergency_floor_direct_items(id,restaurant_id,session_id,order_id,order_item_id,component_menu_item_id,name_ko,name_vi,name_en,ordered_quantity,floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000053','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000013','4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Sting','Sting','Sting',1,1,false);
INSERT INTO public.emergency_fulfillment_events(session_id,order_id,restaurant_id,order_item_id,floor_direct_item_id,combo_component_item_id,stage,delta,created_at) VALUES
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000011',NULL,NULL,'kitchen_done',2,'2026-09-15 10:02Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000011',NULL,NULL,'tray_dispatched',2,'2026-09-15 10:03Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000011',NULL,NULL,'floor_served',2,'2026-09-15 10:04Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000012',NULL,NULL,'kitchen_done',1,'2026-09-15 10:03Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000012',NULL,NULL,'tray_dispatched',1,'2026-09-15 10:04Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000012',NULL,NULL,'floor_served',1,'2026-09-15 10:05Z'),
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c',NULL,'00000000-0000-4000-8000-000000000053',NULL,'floor_served',1,'2026-09-15 10:06Z');

CREATE OR REPLACE FUNCTION public.get_paperless_operations_report_pre_menu_localization(
  store uuid,from_at timestamptz,to_at timestamptz
) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  SELECT public.get_paperless_operations_report_pre_meal_start(store,from_at,to_at)
$function$;
