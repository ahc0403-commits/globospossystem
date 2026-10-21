\set ON_ERROR_STOP on
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
ALTER TABLE public.menu_categories ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
INSERT INTO public.menu_categories(id,restaurant_id,name) VALUES
 ('20000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849','Order test'),
 ('20000000-0000-4000-8000-000000000002','273b057e-3b69-46e3-93c1-6194c2802849','Other category'),
 ('20000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000003','Other store');
DO $$
DECLARE a public.menu_items; b public.menu_items; c public.menu_items; result jsonb;
 frozen text; before_other text; changed text;
 cat uuid:='20000000-0000-4000-8000-000000000001';
 store uuid:='273b057e-3b69-46e3-93c1-6194c2802849';
BEGIN
 a:=public.admin_create_menu_item_with_options(store,cat,'A','A','A','A',100,'{"meal_choices":true,"size_prices":{"S":100,"L":200}}',2);
 b:=public.admin_create_menu_item_with_options(store,cat,'B','B','B','B',100,'{}',4);
 c:=public.admin_create_menu_item_with_options(store,cat,'55K','55K','55K','55K',55,'{}',27);
 INSERT INTO public.menu_items(restaurant_id,category_id,name_ko,name_vi,name_en,price,sort_order,is_archived)
 VALUES(store,cat,'Archived','Archived','Archived',100,90,true),
 (store,'20000000-0000-4000-8000-000000000002','Other','Other','Other',100,8,false);
 SELECT md5(string_agg((to_jsonb(m)-'sort_order'-'updated_at')::text,';' ORDER BY id)) INTO frozen
 FROM public.menu_items m;
 result:=public.admin_move_menu_item(store,cat,c.id,'first');
 IF jsonb_array_length(result)<>3 OR result->0->>'id'<>c.id::text OR result->1->>'id'<>a.id::text THEN RAISE EXCEPTION 'FIRST_FAILED'; END IF;
 IF (SELECT count(*) FROM public.menu_items WHERE size_parent_id=a.id AND NOT is_archived)<>3 THEN RAISE EXCEPTION 'INTERNAL_OPTIONS_CHANGED'; END IF;
 result:=public.admin_move_menu_item(store,cat,c.id,'down');
 IF result->0->>'id'<>a.id::text OR result->1->>'id'<>c.id::text THEN RAISE EXCEPTION 'DOWN_FAILED'; END IF;
 result:=public.admin_move_menu_item(store,cat,b.id,'up');
 IF result->1->>'id'<>b.id::text OR result->2->>'id'<>c.id::text THEN RAISE EXCEPTION 'UP_FAILED'; END IF;
 -- Boundary moves are safe no-ops; hidden and other-category rows are excluded.
 result:=public.admin_move_menu_item(store,cat,a.id,'up');
 result:=public.admin_move_menu_item(store,cat,c.id,'down');
 IF (SELECT count(*) FROM public.audit_logs WHERE action='admin_move_menu_item')<>3 THEN RAISE EXCEPTION 'AUDIT_BOUNDARY_FAILED'; END IF;
 BEGIN
  PERFORM public.admin_move_menu_item(store,'20000000-0000-4000-8000-000000000002',a.id,'first');
  RAISE EXCEPTION 'WRONG_CATEGORY_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'MENU_ITEM_NOT_FOUND' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.admin_move_menu_item(store,'20000000-0000-4000-8000-000000000003',a.id,'first');
  RAISE EXCEPTION 'CROSS_STORE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'MENU_CATEGORY_NOT_FOUND' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.admin_move_menu_item(store,cat,a.id,'invalid');
  RAISE EXCEPTION 'INVALID_MOVE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'MENU_ITEM_ORDER_MOVE_INVALID' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN
  PERFORM public.admin_move_menu_item(store,cat,a.id,'first');
  RAISE EXCEPTION 'UNAUTHENTICATED_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
 SELECT md5(string_agg((to_jsonb(m)-'sort_order'-'updated_at')::text,';' ORDER BY id)) INTO changed
 FROM public.menu_items m;
 IF frozen<>changed THEN RAISE EXCEPTION 'NON_ORDER_MENU_FIELDS_CHANGED'; END IF;
 IF (SELECT sort_order FROM public.menu_items WHERE name_ko='Archived')<>90
 OR (SELECT sort_order FROM public.menu_items WHERE name_ko='Other')<>8 THEN RAISE EXCEPTION 'OUT_OF_SCOPE_ORDER_CHANGED'; END IF;
END $$;
-- 500 rows: one request and one set-based update at category scope.
INSERT INTO public.menu_categories(id,restaurant_id,name) VALUES
 ('20000000-0000-4000-8000-000000000004','273b057e-3b69-46e3-93c1-6194c2802849','Scale order');
INSERT INTO public.menu_items(id,restaurant_id,category_id,name_ko,name_vi,name_en,price,sort_order)
 SELECT md5('menu-order-scale-'||n)::uuid,'273b057e-3b69-46e3-93c1-6194c2802849',
 '20000000-0000-4000-8000-000000000004','Order '||n,'Order '||n,'Order '||n,100,n
 FROM generate_series(1,500)n;
EXPLAIN(ANALYZE,BUFFERS) SELECT public.admin_move_menu_item('273b057e-3b69-46e3-93c1-6194c2802849',
 '20000000-0000-4000-8000-000000000004',md5('menu-order-scale-500')::uuid,'first');
DO $$ BEGIN
 IF (SELECT sort_order FROM public.menu_items WHERE id=md5('menu-order-scale-500')::uuid)<>0
 THEN RAISE EXCEPTION 'SCALE_FIRST_FAILED'; END IF;
END $$;
SELECT 'ADMIN_MENU_ITEM_ORDER_SQL=PASS';
