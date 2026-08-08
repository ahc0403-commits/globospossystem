BEGIN;

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS combo_drink_choice_count smallint NOT NULL DEFAULT 0;

ALTER TABLE public.menu_items
  DROP CONSTRAINT IF EXISTS menu_items_combo_drink_choice_count_check;
ALTER TABLE public.menu_items
  ADD CONSTRAINT menu_items_combo_drink_choice_count_check
  CHECK (combo_drink_choice_count BETWEEN 0 AND 10);

ALTER TABLE public.menu_categories
  DROP CONSTRAINT IF EXISTS menu_categories_system_key_check;
ALTER TABLE public.menu_categories
  ADD CONSTRAINT menu_categories_system_key_check
  CHECK (system_key IS NULL OR system_key IN ('alcohol', 'drink'));

-- Mark the existing beverage category once. Runtime lookups use this stable key,
-- so later category/menu renames do not change combo behavior.
WITH candidates AS (
  SELECT category.id,
         row_number() OVER (
           PARTITION BY category.restaurant_id
           ORDER BY category.sort_order, category.created_at, category.id
         ) AS candidate_rank
  FROM public.menu_categories category
  WHERE category.system_key IS NULL
    AND (
      lower(btrim(COALESCE(category.name, ''))) IN
        ('음료', 'drink', 'drinks', 'beverage', 'beverages', 'đồ uống', 'nước uống')
      OR lower(btrim(COALESCE(category.name_ko, ''))) IN
        ('음료', 'drink', 'drinks', 'beverage', 'beverages', 'đồ uống', 'nước uống')
      OR lower(btrim(COALESCE(category.name_en, ''))) IN
        ('음료', 'drink', 'drinks', 'beverage', 'beverages')
      OR lower(btrim(COALESCE(category.name_vi, ''))) IN
        ('đồ uống', 'nước uống', 'drink', 'drinks', 'beverage', 'beverages')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.menu_categories existing
      WHERE existing.restaurant_id = category.restaurant_id
        AND existing.system_key = 'drink'
    )
)
UPDATE public.menu_categories category
SET system_key = 'drink'
FROM candidates candidate
WHERE category.id = candidate.id
  AND candidate.candidate_rank = 1;

CREATE OR REPLACE FUNCTION public.identify_drink_menu_category()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.system_key IS NULL
     AND (
       lower(btrim(COALESCE(NEW.name, ''))) IN
         ('음료', 'drink', 'drinks', 'beverage', 'beverages', 'đồ uống', 'nước uống')
       OR lower(btrim(COALESCE(NEW.name_ko, ''))) IN
         ('음료', 'drink', 'drinks', 'beverage', 'beverages', 'đồ uống', 'nước uống')
       OR lower(btrim(COALESCE(NEW.name_en, ''))) IN
         ('drink', 'drinks', 'beverage', 'beverages')
       OR lower(btrim(COALESCE(NEW.name_vi, ''))) IN
         ('đồ uống', 'nước uống', 'drink', 'drinks', 'beverage', 'beverages')
     )
     AND NOT EXISTS (
       SELECT 1
       FROM public.menu_categories existing
       WHERE existing.restaurant_id = NEW.restaurant_id
         AND existing.system_key = 'drink'
         AND existing.id IS DISTINCT FROM NEW.id
     ) THEN
    NEW.system_key := 'drink';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS identify_drink_menu_category_trigger
  ON public.menu_categories;
CREATE TRIGGER identify_drink_menu_category_trigger
BEFORE INSERT OR UPDATE ON public.menu_categories
FOR EACH ROW EXECUTE FUNCTION public.identify_drink_menu_category();

CREATE OR REPLACE FUNCTION public.protect_system_menu_category()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.system_key IN ('alcohol', 'drink') THEN
    RAISE EXCEPTION 'MENU_SYSTEM_CATEGORY_PROTECTED';
  END IF;

  IF TG_OP <> 'DELETE' AND NEW.system_key = 'alcohol' THEN
    IF NEW.name IS DISTINCT FROM '주류'
       OR NEW.name_ko IS DISTINCT FROM '주류'
       OR NEW.name_vi IS DISTINCT FROM 'Đồ uống có cồn'
       OR NEW.name_en IS DISTINCT FROM 'Alcohol'
       OR NEW.is_active IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'MENU_ALCOHOL_CATEGORY_NAME_FIXED';
    END IF;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.system_key IN ('alcohol', 'drink')
     AND NEW.system_key IS DISTINCT FROM OLD.system_key THEN
    RAISE EXCEPTION 'MENU_SYSTEM_CATEGORY_PROTECTED';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- One-time compatibility backfill for the existing generic drink slot.
UPDATE public.menu_items combo
SET combo_drink_choice_count = legacy.choice_count
FROM (
  SELECT component.combo_menu_item_id,
         LEAST(sum(component.quantity), 10)::smallint AS choice_count
  FROM public.menu_combo_components component
  JOIN public.menu_items slot_item
    ON slot_item.id = component.component_menu_item_id
   AND slot_item.restaurant_id = component.restaurant_id
  WHERE lower(btrim(COALESCE(NULLIF(slot_item.name_ko, ''), slot_item.name)))
    IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống')
  GROUP BY component.combo_menu_item_id
) legacy
WHERE combo.id = legacy.combo_menu_item_id;

DELETE FROM public.menu_combo_components component
USING public.menu_items slot_item
WHERE slot_item.id = component.component_menu_item_id
  AND slot_item.restaurant_id = component.restaurant_id
  AND lower(btrim(COALESCE(NULLIF(slot_item.name_ko, ''), slot_item.name)))
    IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống');

CREATE OR REPLACE FUNCTION public.admin_set_menu_combo(
  p_item_id uuid,
  p_is_combo boolean,
  p_components jsonb,
  p_drink_choice_count integer
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_item public.menu_items%ROWTYPE;
  v_choice_count integer := COALESCE(p_drink_choice_count, 0);
BEGIN
  IF v_choice_count < 0 OR v_choice_count > 10 THEN
    RAISE EXCEPTION 'MENU_COMBO_DRINK_CONFIG_INVALID';
  END IF;

  IF NOT COALESCE(p_is_combo, false)
     AND v_choice_count <> 0 THEN
    RAISE EXCEPTION 'MENU_COMBO_DRINK_CONFIG_NOT_ALLOWED';
  END IF;

  v_item := public.admin_set_menu_combo(
    p_item_id,
    p_is_combo,
    COALESCE(p_components, '[]'::jsonb)
  );

  UPDATE public.menu_items
  SET combo_drink_choice_count = v_choice_count,
      updated_at = now()
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_set_menu_combo_drinks',
    'menu_items',
    v_item.id,
    jsonb_build_object(
      'store_id', v_item.restaurant_id,
      'drink_choice_count', v_choice_count,
      'updated_at_utc', now()
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.combo_drink_choice_count(
  p_combo_menu_item_id uuid
) RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO public
AS $$
  SELECT COALESCE(combo_drink_choice_count, 0)::integer
  FROM public.menu_items
  WHERE id = p_combo_menu_item_id
    AND is_combo = true;
$$;

CREATE OR REPLACE FUNCTION public.combo_drink_options(
  p_combo_menu_item_id uuid
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO public
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', option_item.id::text,
        'name', option_item.name,
        'name_ko', COALESCE(NULLIF(option_item.name_ko, ''), option_item.name),
        'name_vi', COALESCE(NULLIF(option_item.name_vi, ''), option_item.name),
        'name_en', COALESCE(NULLIF(option_item.name_en, ''), option_item.name)
      )
      ORDER BY option_item.sort_order, option_item.name, option_item.id
    ),
    '[]'::jsonb
  )
  FROM public.menu_items combo
  JOIN public.menu_categories drink_category
    ON drink_category.restaurant_id = combo.restaurant_id
   AND drink_category.system_key = 'drink'
   AND drink_category.is_active = true
  JOIN public.menu_items option_item
    ON option_item.restaurant_id = combo.restaurant_id
   AND option_item.category_id = drink_category.id
  WHERE combo.id = p_combo_menu_item_id
    AND combo.is_combo = true
    AND option_item.is_archived = false
    AND option_item.is_available = true
    AND option_item.is_visible_public = true
    AND option_item.is_combo = false;
$$;

CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_promotion record;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT q.restaurant_id, q.table_id, t.table_number,
         COALESCE(t.floor_label, '1F') AS floor_label, r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT p.id, p.name, p.discount_percent
  INTO v_promotion
  FROM public.store_promotions p
  WHERE p.restaurant_id = v_table.restaurant_id
    AND p.is_active = true
    AND p.starts_at <= now()
    AND p.ends_at > now()
    AND p.channel IN ('both', 'qr')
  ORDER BY p.starts_at DESC
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', c.id::text,
    'name', c.name,
    'name_ko', COALESCE(NULLIF(c.name_ko, ''), c.name),
    'name_vi', COALESCE(NULLIF(c.name_vi, ''), c.name),
    'name_en', COALESCE(NULLIF(c.name_en, ''), c.name),
    'sort_order', c.sort_order
  ) ORDER BY c.sort_order, c.name, c.id), '[]'::jsonb)
  INTO v_categories
  FROM public.menu_categories c
  WHERE c.restaurant_id = v_table.restaurant_id
    AND c.is_active = true
    AND EXISTS (
      SELECT 1 FROM public.menu_items mi
      WHERE mi.restaurant_id = c.restaurant_id
        AND mi.category_id = c.id
        AND mi.is_available = true
        AND mi.is_visible_public = true
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', mi.id::text,
    'category_id', mi.category_id::text,
    'name', mi.name,
    'name_ko', COALESCE(NULLIF(mi.name_ko, ''), mi.name),
    'name_vi', COALESCE(NULLIF(mi.name_vi, ''), mi.name),
    'name_en', COALESCE(NULLIF(mi.name_en, ''), mi.name),
    'description', mi.description,
    'original_price', mi.price,
    'price', CASE
      WHEN v_promotion.id IS NULL THEN mi.price
      ELSE round(mi.price * (100 - v_promotion.discount_percent) / 100, 0)
    END,
    'discount_percent', COALESCE(v_promotion.discount_percent, 0),
    'image_url', mi.image_url,
    'is_combo', mi.is_combo,
    'combo_drink_choice_count', CASE
      WHEN mi.is_combo THEN public.combo_drink_choice_count(mi.id)
      ELSE 0
    END,
    'combo_drink_options', CASE
      WHEN mi.is_combo THEN public.combo_drink_options(mi.id)
      ELSE '[]'::jsonb
    END
  ) ORDER BY COALESCE(mc.sort_order, 0), mi.sort_order, mi.name, mi.id), '[]'::jsonb)
  INTO v_items
  FROM public.menu_items mi
  LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
  WHERE mi.restaurant_id = v_table.restaurant_id
    AND mi.is_available = true
    AND mi.is_visible_public = true
    AND (mc.id IS NULL OR mc.is_active = true);

  RETURN jsonb_build_object(
    'store_id', v_table.restaurant_id::text,
    'store_name', v_table.store_name,
    'table_id', v_table.table_id::text,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'promotion_name', v_promotion.name,
    'promotion_discount_percent', COALESCE(v_promotion.discount_percent, 0),
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.snapshot_order_item_combo_components()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
BEGIN
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

  v_payload_text := current_setting('pos.qr_combo_payload', true);
  IF NULLIF(v_payload_text, '') IS NOT NULL THEN
    SELECT COALESCE(line.raw->'combo_drink_choices', '[]'::jsonb)
    INTO v_selected
    FROM jsonb_array_elements(v_payload_text::jsonb) line(raw)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'menu_item_id', component_item.id::text,
      'label', component_item.name,
      'quantity', component.quantity
    ) ORDER BY component.sort_order, component.created_at, component.id
  ), '[]'::jsonb)
  INTO v_fixed
  FROM public.menu_combo_components component
  JOIN public.menu_items component_item
    ON component_item.id = component.component_menu_item_id
   AND component_item.restaurant_id = component.restaurant_id
  WHERE component.combo_menu_item_id = NEW.menu_item_id
    AND component.restaurant_id = NEW.restaurant_id
    AND (
      jsonb_array_length(v_selected) = 0
      OR lower(btrim(COALESCE(NULLIF(component_item.name_ko, ''), component_item.name)))
        NOT IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống')
    );

  IF jsonb_array_length(v_selected) > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'menu_item_id', selected_item.id::text,
      'label', selected_item.name,
      'quantity', selected.quantity,
      'is_total_quantity', true
    ) ORDER BY selected.first_ordinal), '[]'::jsonb)
    INTO v_drinks
    FROM (
      SELECT choice.value::uuid AS item_id,
             count(*)::integer AS quantity,
             min(choice.ordinality) AS first_ordinal
      FROM jsonb_array_elements_text(v_selected)
        WITH ORDINALITY choice(value, ordinality)
      GROUP BY choice.value
    ) selected
    JOIN public.menu_items selected_item ON selected_item.id = selected.item_id;
  END IF;

  NEW.combo_components := v_fixed || v_drinks;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid,
  p_validate_combo_choices boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_table record;
  v_existing public.qr_order_batches%ROWTYPE;
  v_line record;
  v_choice_count integer;
  v_expected_count integer;
BEGIN
  IF p_client_order_id IS NULL OR jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  IF (
    SELECT count(DISTINCT line.raw->>'menu_item_id')
    FROM jsonb_array_elements(v_items) line(raw)
  ) <> jsonb_array_length(v_items) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_existing
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id
    AND restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id;
  IF FOUND THEN RETURN v_existing.result_snapshot; END IF;

  FOR v_line IN SELECT raw FROM jsonb_array_elements(v_items) line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '')
         !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;

    IF jsonb_typeof(COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb))
         <> 'array' THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    v_choice_count := jsonb_array_length(
      COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb)
    );
    v_expected_count := public.combo_drink_choice_count(
      (v_line.raw->>'menu_item_id')::uuid
    ) * (v_line.raw->>'quantity')::integer;

    IF v_choice_count <> v_expected_count THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    IF v_choice_count > 0 THEN
      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(v_line.raw->'combo_drink_choices') choice(value)
        LEFT JOIN public.menu_items option_item
          ON option_item.id = CASE
               WHEN choice.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
               THEN choice.value::uuid
               ELSE NULL
             END
         AND option_item.restaurant_id = v_table.restaurant_id
         AND option_item.is_archived = false
         AND option_item.is_available = true
         AND option_item.is_visible_public = true
         AND option_item.is_combo = false
        LEFT JOIN public.menu_categories drink_category
          ON drink_category.id = option_item.category_id
         AND drink_category.restaurant_id = v_table.restaurant_id
         AND drink_category.system_key = 'drink'
         AND drink_category.is_active = true
        WHERE option_item.id IS NULL OR drink_category.id IS NULL
      ) THEN
        RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
      END IF;
    END IF;
  END LOOP;

  PERFORM set_config('pos.qr_combo_payload', v_items::text, true);
  RETURN public.qr_place_order(p_token, p_items, p_client_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.combo_drink_choice_count(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_set_menu_combo(uuid, boolean, jsonb, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_combo(uuid, boolean, jsonb, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.combo_drink_options(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_place_order(text, jsonb, uuid, boolean)
  TO anon, authenticated, service_role;

COMMIT;
