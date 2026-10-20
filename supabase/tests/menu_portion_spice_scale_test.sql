\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE store uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; cat uuid; count_rows int; n int; started timestamptz; elapsed numeric;
 payload jsonb; cursor_sort int; cursor_id uuid; bytes int; calls int; input jsonb; sample int; durations numeric[]; p50 numeric; p95 numeric;
BEGIN
 INSERT INTO public.menu_categories(restaurant_id,name,name_ko,name_vi,name_en) VALUES(store,'Scale menu','면','Mì','Noodles') RETURNING id INTO cat;
 INSERT INTO public.direct_order_storefronts(restaurant_id,public_slug,is_enabled,ordering_hours_enforced,accounting_approved_at,accounting_approved_by,bank_bin,bank_account_number,bank_account_holder) VALUES(store,'menu-options-lab',true,false,now(),'92000000-0000-4000-8000-000000000001','970436','LAB001','LAB ONLY');
 FOREACH count_rows IN ARRAY ARRAY[10,100,500] LOOP
  INSERT INTO public.menu_items(restaurant_id,category_id,name,name_ko,name_vi,name_en,price,is_visible_public,portion_code,spice_level)
  SELECT store,cat,'Scale menu '||i,'국수 '||i,'Mì '||i,'Noodles '||i,10000+i,true,CASE WHEN i%2=0 THEN 'S' ELSE 'L' END,'spicy'
  FROM generate_series(1,count_rows) i;
  durations:=ARRAY[]::numeric[];
  FOR sample IN 1..20 LOOP
  calls:=0; bytes:=0; cursor_sort:=null; cursor_id:=null; started:=clock_timestamp();
  LOOP
   payload:=public.direct_order_public_storefront_v3('menu-options-lab',cursor_sort,cursor_id,200);
   calls:=calls+1;bytes:=bytes+octet_length(payload::text);
   EXIT WHEN payload->'next_cursor'='null'::jsonb;
   cursor_sort:=(payload->'next_cursor'->>'sort_order')::int;cursor_id:=(payload->'next_cursor'->>'id')::uuid;
  END LOOP;
  elapsed:=round(extract(epoch FROM clock_timestamp()-started)*1000,3);
  ASSERT calls=ceil(count_rows::numeric/200),payload::text;
  durations:=array_append(durations,elapsed);
  END LOOP;
  SELECT percentile_cont(0.5) WITHIN GROUP(ORDER BY value),percentile_cont(0.95) WITHIN GROUP(ORDER BY value) INTO p50,p95 FROM unnest(durations)value;
  SELECT jsonb_agg(jsonb_build_object('menu_item_id',id,'quantity',1,'menu_option_key',menu_option_key)) INTO input
  FROM(SELECT id,menu_option_key FROM public.menu_items WHERE category_id=cat ORDER BY id LIMIT 50)x;
  started:=clock_timestamp();PERFORM public.validate_menu_option_batch(store,input,'direct');
  RAISE NOTICE 'MENU_OPTION_SCALE menus=% catalog_calls=% bytes=% catalog_p50_ms=% catalog_p95_ms=% validation_lines=% validation_ms=%',count_rows,calls,bytes,round(p50,3),round(p95,3),jsonb_array_length(input),round(extract(epoch FROM clock_timestamp()-started)*1000,3);
  DELETE FROM public.menu_items WHERE category_id=cat;
 END LOOP;
END $$;
ROLLBACK;
