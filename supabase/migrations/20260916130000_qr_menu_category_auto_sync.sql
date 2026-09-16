BEGIN;

-- Existing TOP7 rows were created as POS-only duplicates. Make the curated
-- category orderable from the public table QR menu as requested.
UPDATE public.menu_items AS menu
SET is_visible_public = true,
    updated_at = now()
FROM public.menu_categories AS category
WHERE category.id = menu.category_id
  AND category.restaurant_id = menu.restaurant_id
  AND category.is_active = true
  AND (
    lower(btrim(category.name)) = lower('메뉴 TOP7')
    OR lower(btrim(COALESCE(category.name_ko, ''))) = lower('메뉴 TOP7')
  )
  AND menu.is_archived = false
  AND menu.is_visible_public = false;

-- Menus created from the current admin screen are customer-orderable by
-- default. Administrators can still explicitly switch public visibility off.
CREATE OR REPLACE FUNCTION public.admin_create_menu_item_i18n_paperless(
  p_store_id uuid,
  p_category_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_paperless_name_vi text,
  p_price numeric,
  p_sort_order integer DEFAULT 0,
  p_is_available boolean DEFAULT true
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
  v_paperless_name_vi text := NULLIF(
    btrim(COALESCE(p_paperless_name_vi, '')), ''
  );
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;
  IF char_length(COALESCE(v_paperless_name_vi, '')) > 200 THEN
    RAISE EXCEPTION 'MENU_PAPERLESS_NAME_INVALID';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_store_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items(
    restaurant_id, category_id, name, name_ko, name_vi, name_en,
    paperless_name_vi, price, is_available, is_visible_public, sort_order,
    created_at, updated_at
  ) VALUES (
    p_store_id, p_category_id, btrim(p_name_ko), btrim(p_name_ko),
    btrim(p_name_vi), btrim(p_name_en), v_paperless_name_vi, p_price,
    COALESCE(p_is_available, true), true, COALESCE(p_sort_order, 0),
    now(), now()
  ) RETURNING * INTO v_created;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_create_menu_item', 'menu_items', v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'new_values', jsonb_build_object(
        'name_ko', v_created.name_ko,
        'name_vi', v_created.name_vi,
        'name_en', v_created.name_en,
        'paperless_name_vi', v_created.paperless_name_vi,
        'price', v_created.price,
        'is_visible_public', v_created.is_visible_public
      )
    )
  );
  RETURN v_created;
END;
$$;

-- Return the same active category list the admin manages. Empty categories are
-- intentionally included, so category creation/reordering is reflected on the
-- QR screen immediately. Menu changes already emit a realtime `menu` event and
-- the client also refreshes every 15 seconds.
CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_promotion public.store_promotions%ROWTYPE;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT
    qr.restaurant_id,
    qr.table_id,
    table_row.table_number,
    COALESCE(table_row.floor_label, '1F') AS floor_label,
    restaurant.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id
   AND restaurant.is_active = true
  WHERE qr.token = v_token
    AND qr.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT * INTO v_promotion
  FROM public.store_promotions promotion
  WHERE promotion.restaurant_id = v_table.restaurant_id
    AND promotion.is_active = true
    AND promotion.starts_at <= now()
    AND promotion.ends_at > now()
    AND promotion.channel IN ('both', 'qr')
  ORDER BY promotion.starts_at DESC
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', category.id::text,
    'name', category.name,
    'name_ko', COALESCE(NULLIF(category.name_ko, ''), category.name),
    'name_vi', COALESCE(NULLIF(category.name_vi, ''), category.name),
    'name_en', COALESCE(NULLIF(category.name_en, ''), category.name),
    'sort_order', category.sort_order
  ) ORDER BY category.sort_order, category.name, category.id), '[]'::jsonb)
  INTO v_categories
  FROM public.menu_categories category
  WHERE category.restaurant_id = v_table.restaurant_id
    AND category.is_active = true;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', menu.id::text,
    'category_id', menu.category_id::text,
    'name', menu.name,
    'name_ko', COALESCE(NULLIF(menu.name_ko, ''), menu.name),
    'name_vi', COALESCE(NULLIF(menu.name_vi, ''), menu.name),
    'name_en', COALESCE(NULLIF(menu.name_en, ''), menu.name),
    'description', menu.description,
    'original_price', menu.price,
    'price', CASE
      WHEN v_promotion.id IS NULL THEN menu.price
      WHEN v_promotion.scope = 'selected_items'
           AND NOT EXISTS (
             SELECT 1
             FROM public.store_promotion_menu_items target
             WHERE target.promotion_id = v_promotion.id
               AND target.restaurant_id = v_table.restaurant_id
               AND target.menu_item_id = menu.id
           ) THEN menu.price
      ELSE ROUND(
        menu.price * (100 - v_promotion.discount_percent) / 100,
        0
      )
    END,
    'discount_percent', CASE
      WHEN v_promotion.id IS NULL THEN 0
      WHEN v_promotion.scope = 'selected_items'
           AND NOT EXISTS (
             SELECT 1
             FROM public.store_promotion_menu_items target
             WHERE target.promotion_id = v_promotion.id
               AND target.restaurant_id = v_table.restaurant_id
               AND target.menu_item_id = menu.id
           ) THEN 0
      ELSE v_promotion.discount_percent
    END,
    'image_url', menu.image_url,
    'is_combo', menu.is_combo,
    'combo_drink_choice_count', CASE
      WHEN menu.is_combo THEN public.combo_drink_choice_count(menu.id)
      ELSE 0
    END,
    'combo_drink_options', CASE
      WHEN menu.is_combo THEN public.combo_drink_options(menu.id)
      ELSE '[]'::jsonb
    END
  ) ORDER BY
      COALESCE(category.sort_order, 0),
      menu.sort_order,
      menu.name,
      menu.id
  ), '[]'::jsonb)
  INTO v_items
  FROM public.menu_items menu
  LEFT JOIN public.menu_categories category
    ON category.id = menu.category_id
   AND category.restaurant_id = menu.restaurant_id
  WHERE menu.restaurant_id = v_table.restaurant_id
    AND menu.is_archived = false
    AND menu.is_available = true
    AND menu.is_visible_public = true
    AND (category.id IS NULL OR category.is_active = true);

  RETURN jsonb_build_object(
    'store_id', v_table.restaurant_id::text,
    'store_name', v_table.store_name,
    'table_id', v_table.table_id::text,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'promotion_name', v_promotion.name,
    'promotion_discount_percent', COALESCE(v_promotion.discount_percent, 0),
    'promotion_scope', COALESCE(v_promotion.scope, 'all_menu'),
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

COMMIT;
