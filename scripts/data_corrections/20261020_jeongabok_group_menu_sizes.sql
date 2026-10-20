-- Owner correction: one registered dish with S/L prices; retain all order IDs.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='40s';
DO $group_sizes$
DECLARE target uuid:='273b057e-3b69-46e3-93c1-6194c2802849';
 pairs jsonb:=$pairs$[{"parent_id": "2aacf99e-c367-459d-95fc-bd6eeafdb581", "large_id": "ee68ab7e-da44-47e7-9b85-980c044cf3ae", "base_name": "탕수육", "S": 190000, "L": 370000}, {"parent_id": "eea97a51-0d00-4a00-9ae8-cb5aac286250", "large_id": "e335587f-c0d8-4d45-bc6a-2569bfc36485", "base_name": "칠리탕수육", "S": 210000, "L": 390000}, {"parent_id": "0adbf24b-0b3a-46eb-b9d6-bc46e8bc3717", "large_id": "956415a5-2f6c-49ba-8be2-fb65ad0831c1", "base_name": "깐풍육", "S": 210000, "L": 390000}, {"parent_id": "f4529a53-2cc3-430e-87ba-797f1aa7c73b", "large_id": "796bd82a-952d-4f9b-ba3c-2b004d607f1c", "base_name": "깐풍기", "S": 210000, "L": 390000}, {"parent_id": "4dd2c791-4958-44b2-8fbb-54fac7a52d48", "large_id": "6cc89ae0-c3f7-4d6b-a415-3d5adb8a2b33", "base_name": "칠리새우", "S": 240000, "L": 390000}, {"parent_id": "c4ac56c5-d002-4346-8163-c45e9e8388cf", "large_id": "c6e2e471-f85f-4836-98dc-19ea3f09fa72", "base_name": "크림새우", "S": 240000, "L": 390000}, {"parent_id": "8ba9afc8-f084-458f-bea6-004a84b0f9d7", "large_id": "cdb141a9-aace-46ac-84c1-5de02ce01173", "base_name": "깐풍새우", "S": 240000, "L": 390000}]$pairs$::jsonb;
 before_other text; before_target text; changed int;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('jeongabok-menu-sizes:'||target::text,0));
 PERFORM id FROM public.menu_items WHERE restaurant_id=target ORDER BY id FOR UPDATE;
 IF (SELECT count(*) FROM public.menu_items WHERE restaurant_id=target)<>47
 OR EXISTS(SELECT 1 FROM public.menu_items WHERE restaurant_id=target AND (size_prices<>'{}' OR size_parent_id IS NOT NULL)) THEN RAISE EXCEPTION 'SIZE_GROUPING_REQUIRES_ORIGINAL_47'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(pairs)x
  LEFT JOIN public.menu_items s ON s.id=(x->>'parent_id')::uuid AND s.restaurant_id=target AND s.portion_code='S' AND s.price=(x->>'S')::numeric
  LEFT JOIN public.menu_items l ON l.id=(x->>'large_id')::uuid AND l.restaurant_id=target AND l.portion_code='L' AND l.price=(x->>'L')::numeric
  WHERE s.id IS NULL OR l.id IS NULL OR s.option_base_names->>'name'<>x->>'base_name' OR l.option_base_names->>'name'<>x->>'base_name'
   OR s.category_id<>l.category_id OR s.spice_level<>l.spice_level OR s.spice_choice<>l.spice_choice) THEN RAISE EXCEPTION 'SIZE_GROUPING_SOURCE_CHANGED'; END IF;
 SELECT md5(coalesce(jsonb_agg(to_jsonb(m)-'size_prices'-'size_parent_id' ORDER BY id)::text,'[]')) INTO before_other FROM public.menu_items m WHERE restaurant_id<>target;
 SELECT md5(jsonb_agg(to_jsonb(m)-'size_prices'-'size_parent_id'-'menu_option_key'-'updated_at' ORDER BY id)::text) INTO before_target FROM public.menu_items m WHERE restaurant_id=target;
 UPDATE public.menu_items m SET size_prices=jsonb_build_object('S',(x->>'S')::numeric,'L',(x->>'L')::numeric)
 FROM jsonb_array_elements(pairs)x WHERE m.id=(x->>'parent_id')::uuid AND m.restaurant_id=target;
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>7 THEN RAISE EXCEPTION 'SIZE_PARENT_COUNT_CHANGED'; END IF;
 UPDATE public.menu_items m SET size_parent_id=(x->>'parent_id')::uuid
 FROM jsonb_array_elements(pairs)x WHERE m.id=(x->>'large_id')::uuid AND m.restaurant_id=target;
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>7 THEN RAISE EXCEPTION 'SIZE_PRICE_COUNT_CHANGED'; END IF;
 IF (SELECT count(*) FROM public.menu_items WHERE restaurant_id=target AND size_parent_id IS NULL AND NOT is_archived)<>40
 OR (SELECT count(*) FROM public.menu_items WHERE restaurant_id=target AND is_visible_public AND is_available AND NOT is_archived)<>47
 OR before_other<>(SELECT md5(coalesce(jsonb_agg(to_jsonb(m)-'size_prices'-'size_parent_id' ORDER BY id)::text,'[]')) FROM public.menu_items m WHERE restaurant_id<>target)
 OR before_target<>(SELECT md5(jsonb_agg(to_jsonb(m)-'size_prices'-'size_parent_id'-'menu_option_key'-'updated_at' ORDER BY id)::text) FROM public.menu_items m WHERE restaurant_id=target) THEN RAISE EXCEPTION 'SIZE_GROUPING_PRESERVATION_FAILED'; END IF;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(NULL,'jeongabok_menu_sizes_grouped','restaurants',target,jsonb_build_object('operator','Codex maintenance','owner_request','One menu with S/L price selection; not separate registrations','catalog_menus',40,'sized_menus',7,'all_sellable_prices',47,'other_store_menus_unchanged',true,'original_price_name_tax_fields_unchanged',true));
END $group_sizes$;
SELECT 'JEONGABOK_SIZE_GROUPING=PASS' AS result;
COMMIT;
