\set ON_ERROR_STOP on

BEGIN;

DO $contract$
DECLARE
  v_company uuid := gen_random_uuid();
  v_brand_master uuid := gen_random_uuid();
  v_brand uuid := gen_random_uuid();
  v_tax uuid := gen_random_uuid();
  v_store uuid := gen_random_uuid();
  v_auth uuid := gen_random_uuid();
  v_user uuid;
  v_category uuid := gen_random_uuid();
  v_archived_category uuid := gen_random_uuid();
  v_item uuid := gen_random_uuid();
  v_category_item uuid := gen_random_uuid();
  v_component uuid := gen_random_uuid();
  v_combo uuid := gen_random_uuid();
  v_forbidden_item uuid := gen_random_uuid();
  v_blocked boolean := false;
BEGIN
  INSERT INTO public.companies(id, name)
  VALUES (v_company, 'Menu archive fixture');
  INSERT INTO public.brand_master(id, company_id, name, type)
  VALUES (v_brand_master, v_company, 'Menu archive fixture', 'internal');
  INSERT INTO public.brands(id, code, name, brand_master_id)
  VALUES (v_brand, 'menu_archive_fixture', 'Menu archive fixture', v_brand_master);
  INSERT INTO public.tax_entity(id, tax_code, name, owner_type)
  VALUES (v_tax, 'MENU-ARCHIVE-FIXTURE', 'Menu archive fixture', 'internal');
  INSERT INTO public.restaurants(id, name, brand_id, tax_entity_id)
  VALUES (v_store, 'Menu archive fixture', v_brand, v_tax);
  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'menu-archive-fixture@example.test');
  INSERT INTO public.users(auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_auth, v_store, 'admin', 'Menu Archive Admin', true)
  RETURNING id INTO v_user;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);

  INSERT INTO public.menu_categories(
    id, restaurant_id, name, name_ko, name_vi, name_en, sort_order
  ) VALUES
    (v_category, v_store, 'Main', '메인', 'Món chính', 'Main', 0),
    (
      v_archived_category, v_store, 'Archive', '보관', 'Lưu trữ',
      'Archive', 1
    );

  INSERT INTO public.menu_items(
    id, restaurant_id, category_id, name, name_ko, name_vi, name_en,
    price, is_available, is_visible_public, sort_order, image_url,
    image_storage_path, is_combo
  ) VALUES
    (
      v_item, v_store, v_category, 'Delete me', '삭제 메뉴', 'Món cần xóa',
      'Delete me', 10000, true, true, 0,
      'https://fixture.invalid/menu.jpg', 'fixture/menu.jpg', false
    ),
    (
      v_category_item, v_store, v_archived_category, 'Only item',
      '유일 메뉴', 'Món duy nhất', 'Only item', 12000, true, true, 0,
      null, null, false
    ),
    (
      v_component, v_store, v_category, 'Component', '구성 메뉴',
      'Món thành phần', 'Component', 5000, true, true, 1,
      null, null, false
    ),
    (
      v_combo, v_store, v_category, 'Combo', '콤보', 'Combo', 'Combo',
      15000, true, true, 2, null, null, true
    ),
    (
      v_forbidden_item, v_store, v_category, 'Forbidden', '권한 메뉴',
      'Món quyền hạn', 'Forbidden', 8000, true, true, 3,
      null, null, false
    );

  INSERT INTO public.menu_combo_components(
    restaurant_id, combo_menu_item_id, component_menu_item_id, quantity,
    sort_order
  ) VALUES (v_store, v_combo, v_component, 1, 0);

  PERFORM public.admin_archive_menu_item(v_item);
  IF NOT EXISTS (
    SELECT 1
    FROM public.menu_items item
    WHERE item.id = v_item
      AND item.is_archived
      AND NOT item.is_available
      AND NOT item.is_visible_public
      AND item.image_url = 'https://fixture.invalid/menu.jpg'
      AND item.image_storage_path = 'fixture/menu.jpg'
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_STATE_OR_IMAGE_PRESERVATION_FAILED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = v_item AND is_archived = false
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_ACTIVE_CATALOG_FILTER_FAILED';
  END IF;
  IF (
    SELECT count(*)
    FROM public.audit_logs
    WHERE entity_id = v_item
      AND action = 'admin_delete_menu_item'
      AND details ->> 'delete_mode' = 'archive'
  ) <> 1 THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_AUDIT_MISSING';
  END IF;

  PERFORM public.admin_archive_menu_item(v_item);
  IF (
    SELECT count(*) FROM public.audit_logs
    WHERE entity_id = v_item
      AND action = 'admin_delete_menu_item'
      AND details ->> 'delete_mode' = 'archive'
  ) <> 1 THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_RETRY_DUPLICATED_AUDIT';
  END IF;

  BEGIN
    PERFORM public.admin_archive_menu_item(v_component);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%MENU_COMBO_COMPONENT_IN_USE%';
  END;
  IF NOT v_blocked OR EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = v_component AND is_archived
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_ACTIVE_COMBO_COMPONENT_NOT_BLOCKED';
  END IF;

  PERFORM public.admin_archive_menu_item(v_combo);
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_combo_components
    WHERE combo_menu_item_id = v_combo
      AND component_menu_item_id = v_component
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_COMBO_RELATION_WAS_DELETED';
  END IF;

  PERFORM public.admin_archive_menu_item(v_category_item);
  PERFORM public.admin_delete_menu_category(v_archived_category);
  IF EXISTS (
    SELECT 1 FROM public.menu_categories WHERE id = v_archived_category
  ) OR NOT EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = v_category_item
      AND is_archived
      AND category_id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_CATEGORY_DELETE_COMPATIBILITY_FAILED';
  END IF;

  UPDATE public.users SET role = 'waiter' WHERE id = v_user;
  v_blocked := false;
  BEGIN
    PERFORM public.admin_archive_menu_item(v_forbidden_item);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%ADMIN_MUTATION_FORBIDDEN%';
  END;
  IF NOT v_blocked OR EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = v_forbidden_item AND is_archived
  ) THEN
    RAISE EXCEPTION 'MENU_ARCHIVE_PERMISSION_GUARD_FAILED';
  END IF;

  RAISE NOTICE 'PASS: menu archive state, audit, idempotency, combo guard, category compatibility, and permission';
END;
$contract$;

ROLLBACK;

SELECT 'ADMIN_MENU_ITEM_ARCHIVE_RUNTIME_CONTRACT_OK' AS result;
