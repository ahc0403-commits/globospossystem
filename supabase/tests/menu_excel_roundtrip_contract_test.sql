\set ON_ERROR_STOP on

BEGIN;

DO $contract$
DECLARE
  v_store uuid := 'a7000000-0000-4000-8000-000000000001';
  v_auth uuid := 'a7000000-0000-4000-8000-000000000002';
  v_user uuid := 'a7000000-0000-4000-8000-000000000003';
  v_category uuid := 'a7000000-0000-4000-8000-000000000004';
  v_item uuid := 'a7000000-0000-4000-8000-000000000005';
  v_blocked boolean := false;
  v_result jsonb;
BEGIN
  INSERT INTO public.restaurants(
    id, name, address, is_active, brand_id, tax_entity_id
  )
  SELECT
    v_store, 'Menu Roundtrip Contract Store', 'test', true,
    r.brand_id, r.tax_entity_id
  FROM public.restaurants r
  WHERE r.brand_id IS NOT NULL AND r.tax_entity_id IS NOT NULL
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_TEST_REQUIRES_STORE_FIXTURE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'menu.roundtrip.contract@invalid.local');
  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_user, v_auth, v_store, 'admin', 'Menu Roundtrip Admin', true
  );
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');

  INSERT INTO public.menu_categories(
    id, restaurant_id, name, name_ko, name_vi, name_en, sort_order
  ) VALUES (
    v_category, v_store, '분식', '분식', 'Món ăn Hàn Quốc',
    'Korean food', 0
  );
  INSERT INTO public.menu_items(
    id, restaurant_id, category_id, name, name_ko, name_vi, name_en,
    description, price, is_available, is_visible_public, sort_order,
    image_url, image_storage_path
  ) VALUES (
    v_item, v_store, v_category, '떡볶이', '떡볶이', 'Tokbokki',
    'Spicy rice cakes', 'old', 50000, true, true, 0,
    'https://fixture.invalid/menu.jpg', 'fixture/menu.jpg'
  );

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);

  v_result := public.admin_update_menu_workbook_i18n(
    v_store,
    jsonb_build_array(jsonb_build_object(
      'source_row', 2,
      'store_id', v_store,
      'category_id', v_category,
      'name_ko', '길거리 음식',
      'name_vi', 'Món ăn đường phố',
      'name_en', 'Street food',
      'sort_order', 3
    )),
    jsonb_build_array(jsonb_build_object(
      'source_row', 2,
      'store_id', v_store,
      'category_id', v_category,
      'item_id', v_item,
      'name_ko', '매운 떡볶이',
      'name_vi', 'Bánh gạo cay',
      'name_en', 'Spicy tteokbokki',
      'description', 'new',
      'price', 55000,
      'is_available', true,
      'is_visible_public', false,
      'sort_order', 4
    ))
  );

  IF v_result <> jsonb_build_object(
    'updated_category_count', 1,
    'updated_item_count', 1
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_RESULT_INVALID:%', v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE id = v_category
      AND name = '길거리 음식'
      AND name_ko = '길거리 음식'
      AND name_vi = 'Món ăn đường phố'
      AND name_en = 'Street food'
      AND sort_order = 3
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_CATEGORY_UPDATE_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = v_item
      AND category_id = v_category
      AND name = '매운 떡볶이'
      AND name_ko = '매운 떡볶이'
      AND name_vi = 'Bánh gạo cay'
      AND name_en = 'Spicy tteokbokki'
      AND price = 55000
      AND is_visible_public = false
      AND image_url = 'https://fixture.invalid/menu.jpg'
      AND image_storage_path = 'fixture/menu.jpg'
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_ITEM_UPDATE_OR_IMAGE_PRESERVATION_FAILED';
  END IF;

  BEGIN
    PERFORM public.admin_update_menu_workbook_i18n(
      v_store,
      jsonb_build_array(jsonb_build_object(
        'source_row', 2,
        'store_id', v_store,
        'category_id', v_category,
        'name_ko', '롤백 대상',
        'name_vi', 'Phải hoàn tác',
        'name_en', 'Must roll back',
        'sort_order', 9
      )),
      jsonb_build_array(jsonb_build_object(
        'source_row', 2,
        'store_id', v_store,
        'category_id', 'a7000000-0000-4000-8000-000000000099',
        'item_id', v_item,
        'name_ko', '실패',
        'name_vi', 'Lỗi',
        'name_en', 'Failure',
        'description', null,
        'price', 60000,
        'is_available', true,
        'is_visible_public', true,
        'sort_order', 0
      ))
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%MENU_WORKBOOK_ITEM_CATEGORY_MISMATCH%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_CATEGORY_MISMATCH_NOT_BLOCKED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE id = v_category AND name_ko = '길거리 음식' AND sort_order = 3
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_ATOMIC_ROLLBACK_FAILED';
  END IF;

  IF (
    SELECT count(*) FROM public.audit_logs
    WHERE entity_id IN (v_category, v_item)
      AND details ->> 'source' = 'excel_roundtrip'
  ) <> 2 THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_AUDIT_LOGS_MISSING';
  END IF;
END;
$contract$;

ROLLBACK;

SELECT 'MENU_EXCEL_ROUNDTRIP_RUNTIME_CONTRACT_OK' AS result;
