BEGIN;

-- production-gate: self-verifying

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS paperless_name_vi text;

COMMENT ON COLUMN public.menu_items.paperless_name_vi IS
  'Optional Vietnamese-only short name for kitchen, tray, and floor paperless KDS. NULL falls back to name_vi.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.menu_items'::regclass
      AND conname = 'menu_items_paperless_name_vi_valid'
  ) THEN
    ALTER TABLE public.menu_items
      ADD CONSTRAINT menu_items_paperless_name_vi_valid CHECK (
        paperless_name_vi IS NULL
        OR (
          btrim(paperless_name_vi) <> ''
          AND char_length(btrim(paperless_name_vi)) <= 200
        )
      );
  END IF;
END;
$$;

-- Keep the old RPCs intact for older clients. New clients use additive RPCs
-- that atomically manage the optional paperless-only Vietnamese name.
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
    SELECT 1 FROM public.menu_categories
    WHERE id = p_category_id AND restaurant_id = p_store_id
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
    COALESCE(p_is_available, true), false, COALESCE(p_sort_order, 0),
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
        'price', v_created.price
      )
    )
  );
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_menu_item_i18n_paperless(
  p_item_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_paperless_name_vi text,
  p_price numeric
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
  v_paperless_name_vi text := NULLIF(
    btrim(COALESCE(p_paperless_name_vi, '')), ''
  );
BEGIN
  SELECT * INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);
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

  UPDATE public.menu_items
  SET name = btrim(p_name_ko),
      name_ko = btrim(p_name_ko),
      name_vi = btrim(p_name_vi),
      name_en = btrim(p_name_en),
      paperless_name_vi = v_paperless_name_vi,
      price = p_price,
      updated_at = now()
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_update_menu_item', 'menu_items', v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.restaurant_id,
      'old_values', jsonb_build_object(
        'name_ko', v_existing.name_ko,
        'name_vi', v_existing.name_vi,
        'name_en', v_existing.name_en,
        'paperless_name_vi', v_existing.paperless_name_vi,
        'price', v_existing.price
      ),
      'new_values', jsonb_build_object(
        'name_ko', v_updated.name_ko,
        'name_vi', v_updated.name_vi,
        'name_en', v_updated.name_en,
        'paperless_name_vi', v_updated.paperless_name_vi,
        'price', v_updated.price
      )
    )
  );
  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_menu_item_i18n_paperless(
  uuid, uuid, text, text, text, text, numeric, integer, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_i18n_paperless(
  uuid, uuid, text, text, text, text, numeric, integer, boolean
) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_i18n_paperless(
  uuid, text, text, text, text, numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_item_i18n_paperless(
  uuid, text, text, text, text, numeric
) TO authenticated;

-- Wrap the current atomic catalog replacement. Omitting the new workbook
-- column preserves existing paperless names; an explicitly blank cell clears
-- the override and restores the normal Vietnamese-name fallback.
ALTER FUNCTION public.admin_update_menu_workbook_i18n(uuid, jsonb, jsonb)
  RENAME TO admin_update_menu_workbook_i18n_catalog;

REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n_catalog(
  uuid, jsonb, jsonb
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_update_menu_workbook_i18n(
  p_store_id uuid,
  p_categories jsonb,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_entry jsonb;
  v_item_id uuid;
  v_existing public.menu_items%ROWTYPE;
  v_paperless_name_vi text;
BEGIN
  v_result := public.admin_update_menu_workbook_i18n_catalog(
    p_store_id, p_categories, p_items
  );

  FOR v_entry IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    IF NOT v_entry ? 'paperless_name_vi' THEN CONTINUE; END IF;
    IF jsonb_typeof(v_entry -> 'paperless_name_vi') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_PAPERLESS_NAME_INVALID:%',
        COALESCE(v_entry ->> 'source_row', '?');
    END IF;
    v_paperless_name_vi := NULLIF(
      btrim(COALESCE(v_entry ->> 'paperless_name_vi', '')), ''
    );
    IF char_length(COALESCE(v_paperless_name_vi, '')) > 200 THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_PAPERLESS_NAME_INVALID:%',
        COALESCE(v_entry ->> 'source_row', '?');
    END IF;
    v_item_id := (v_entry ->> 'item_id')::uuid;
    SELECT * INTO v_existing
    FROM public.menu_items
    WHERE id = v_item_id AND restaurant_id = p_store_id
    FOR UPDATE;

    IF v_existing.paperless_name_vi IS DISTINCT FROM v_paperless_name_vi THEN
      UPDATE public.menu_items
      SET paperless_name_vi = v_paperless_name_vi, updated_at = now()
      WHERE id = v_item_id AND restaurant_id = p_store_id;

      INSERT INTO public.audit_logs(
        actor_id, action, entity_type, entity_id, details
      ) VALUES (
        auth.uid(), 'admin_update_menu_item', 'menu_items', v_item_id,
        jsonb_build_object(
          'store_id', p_store_id,
          'source', 'excel_roundtrip',
          'source_row', v_entry ->> 'source_row',
          'old_values', jsonb_build_object(
            'paperless_name_vi', v_existing.paperless_name_vi
          ),
          'new_values', jsonb_build_object(
            'paperless_name_vi', v_paperless_name_vi
          )
        )
      );
    END IF;
  END LOOP;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(
  uuid, jsonb, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(
  uuid, jsonb, jsonb
) TO authenticated;

-- Localize the existing snapshot payload instead of duplicating its routing,
-- quantity, timing, recent-completion, and floor-direct behavior.
CREATE OR REPLACE FUNCTION public.emergency_localize_paperless_orders(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_order jsonb;
  v_items jsonb;
  v_item jsonb;
  v_components jsonb;
  v_component jsonb;
  v_item_name_vi text;
  v_component_name_vi text;
BEGIN
  IF COALESCE(jsonb_typeof(p_orders), 'null') <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;

  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders)
  LOOP
    v_items := '[]'::jsonb;
    FOR v_item IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(v_order -> 'items', '[]'::jsonb))
    LOOP
      v_item_name_vi := NULL;
      IF v_item ->> 'fulfillment_route' = 'floor_direct' THEN
        SELECT NULLIF(btrim(menu.paperless_name_vi), '')
        INTO v_item_name_vi
        FROM public.emergency_floor_direct_items direct
        JOIN public.menu_items menu
          ON menu.id = direct.component_menu_item_id
        WHERE direct.id::text = v_item ->> 'id';
      ELSE
        SELECT NULLIF(btrim(menu.paperless_name_vi), '')
        INTO v_item_name_vi
        FROM public.order_items order_item
        JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
        WHERE order_item.id::text = v_item ->> 'order_item_id';
      END IF;

      v_components := '[]'::jsonb;
      FOR v_component IN
        SELECT value
        FROM jsonb_array_elements(
          COALESCE(v_item -> 'combo_components', '[]'::jsonb)
        )
      LOOP
        SELECT NULLIF(btrim(menu.paperless_name_vi), '')
        INTO v_component_name_vi
        FROM public.menu_items menu
        WHERE menu.id::text = v_component ->> 'menu_item_id';
        v_component := v_component || jsonb_build_object(
          'name_vi', COALESCE(
            v_component_name_vi,
            NULLIF(v_component ->> 'name_vi', ''),
            'Món'
          )
        );
        v_components := v_components || jsonb_build_array(v_component);
      END LOOP;

      v_item := v_item || jsonb_build_object(
        'name_vi', COALESCE(
          v_item_name_vi, NULLIF(v_item ->> 'name_vi', ''), 'Món'
        ),
        'combo_components', v_components
      );
      v_items := v_items || jsonb_build_array(v_item);
    END LOOP;
    v_order := jsonb_set(v_order, '{items}', v_items, true);
    v_result := v_result || jsonb_build_array(v_order);
  END LOOP;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_localize_paperless_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_base;
ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_base;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_base()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed_base()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := public.get_emergency_station_snapshot_base();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(
      v_payload,
      '{orders}',
      public.emergency_localize_paperless_orders(v_payload -> 'orders'),
      true
    );
  END IF;
  RETURN v_payload;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  RETURN public.emergency_localize_paperless_orders(
    public.get_emergency_station_today_completed_base()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

DO $$
DECLARE
  v_snapshot_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'paperless_name_vi'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_NAME_COLUMN_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_snapshot()'::regprocedure
  ) INTO v_snapshot_definition;
  IF v_snapshot_definition NOT LIKE '%emergency_localize_paperless_orders%' THEN
    RAISE EXCEPTION 'PAPERLESS_KDS_SNAPSHOT_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.admin_update_menu_item_i18n_paperless(uuid,text,text,text,text,numeric)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.admin_update_menu_item_i18n_paperless(uuid,text,text,text,text,numeric)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_MENU_RPC_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
