-- Menu category reordering and restaurant combo-menu composition.

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS is_combo boolean NOT NULL DEFAULT false;

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS combo_components jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.order_items
  DROP CONSTRAINT IF EXISTS order_items_combo_components_array_check;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_combo_components_array_check
  CHECK (jsonb_typeof(combo_components) = 'array');

CREATE TABLE IF NOT EXISTS public.menu_combo_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  combo_menu_item_id uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE CASCADE,
  component_menu_item_id uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE RESTRICT,
  quantity integer NOT NULL CHECK (quantity > 0 AND quantity <= 99),
  sort_order integer NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT menu_combo_component_not_self
    CHECK (combo_menu_item_id <> component_menu_item_id),
  CONSTRAINT menu_combo_component_unique
    UNIQUE (combo_menu_item_id, component_menu_item_id)
);

CREATE INDEX IF NOT EXISTS menu_combo_components_store_idx
  ON public.menu_combo_components(restaurant_id, combo_menu_item_id, sort_order);

ALTER TABLE public.menu_combo_components ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_combo_components_select_accessible_store
  ON public.menu_combo_components;
CREATE POLICY menu_combo_components_select_accessible_store
ON public.menu_combo_components
FOR SELECT
TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
    WHERE accessible.store_id = menu_combo_components.restaurant_id
  )
);

REVOKE ALL ON TABLE public.menu_combo_components FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.menu_combo_components
  FROM authenticated;
GRANT SELECT ON TABLE public.menu_combo_components TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_reorder_menu_categories(
  p_store_id uuid,
  p_category_ids uuid[]
) RETURNS SETOF public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_expected_count integer;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_category_ids IS NULL OR cardinality(p_category_ids) = 0 THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_REQUIRED';
  END IF;

  IF cardinality(p_category_ids) <> (
    SELECT count(DISTINCT input.category_id)
    FROM unnest(p_category_ids) AS input(category_id)
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_DUPLICATE';
  END IF;

  SELECT count(*)
  INTO v_expected_count
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id;

  IF v_expected_count <> cardinality(p_category_ids)
     OR EXISTS (
       SELECT id
       FROM public.menu_categories
       WHERE restaurant_id = p_store_id
       EXCEPT
       SELECT input.category_id
       FROM unnest(p_category_ids) AS input(category_id)
     )
     OR EXISTS (
       SELECT input.category_id
       FROM unnest(p_category_ids) AS input(category_id)
       EXCEPT
       SELECT id
       FROM public.menu_categories
       WHERE restaurant_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_SCOPE_MISMATCH';
  END IF;

  PERFORM 1
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
  FOR UPDATE;

  UPDATE public.menu_categories category
  SET sort_order = ordered.ordinality - 1
  FROM unnest(p_category_ids) WITH ORDINALITY ordered(category_id, ordinality)
  WHERE category.id = ordered.category_id
    AND category.restaurant_id = p_store_id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_reorder_menu_categories',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'category_ids', to_jsonb(p_category_ids),
      'updated_at_utc', now()
    )
  );

  RETURN QUERY
  SELECT *
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
  ORDER BY sort_order, created_at, id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_menu_combo(
  p_item_id uuid,
  p_is_combo boolean,
  p_components jsonb DEFAULT '[]'::jsonb
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_item public.menu_items%ROWTYPE;
  v_components jsonb := COALESCE(p_components, '[]'::jsonb);
  v_component_count integer;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_item
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_item.restaurant_id);

  IF jsonb_typeof(v_components) <> 'array' THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENTS_INVALID';
  END IF;

  IF NOT COALESCE(p_is_combo, false) AND jsonb_array_length(v_components) > 0 THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENTS_NOT_ALLOWED';
  END IF;

  IF COALESCE(p_is_combo, false) AND jsonb_array_length(v_components) = 0 THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENT_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_components) component
    WHERE NULLIF(component->>'menu_item_id', '') IS NULL
       OR NULLIF(component->>'quantity', '') IS NULL
       OR (component->>'quantity')::integer <= 0
       OR (component->>'quantity')::integer > 99
  ) THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENTS_INVALID';
  END IF;

  SELECT count(*)
  INTO v_component_count
  FROM (
    SELECT DISTINCT (component->>'menu_item_id')::uuid AS component_id
    FROM jsonb_array_elements(v_components) component
  ) distinct_components;

  IF v_component_count <> jsonb_array_length(v_components) THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENT_DUPLICATE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_components) component
    LEFT JOIN public.menu_items candidate
      ON candidate.id = (component->>'menu_item_id')::uuid
     AND candidate.restaurant_id = v_item.restaurant_id
    WHERE candidate.id IS NULL
       OR candidate.id = v_item.id
       OR candidate.is_combo = true
  ) THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENT_NOT_ALLOWED';
  END IF;

  DELETE FROM public.menu_combo_components
  WHERE combo_menu_item_id = v_item.id;

  IF COALESCE(p_is_combo, false) THEN
    INSERT INTO public.menu_combo_components(
      restaurant_id,
      combo_menu_item_id,
      component_menu_item_id,
      quantity,
      sort_order
    )
    SELECT
      v_item.restaurant_id,
      v_item.id,
      (component.raw->>'menu_item_id')::uuid,
      (component.raw->>'quantity')::integer,
      component.ordinality - 1
    FROM jsonb_array_elements(v_components)
      WITH ORDINALITY component(raw, ordinality)
    ORDER BY component.ordinality;
  END IF;

  UPDATE public.menu_items
  SET is_combo = COALESCE(p_is_combo, false),
      updated_at = now()
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_set_menu_combo',
    'menu_items',
    v_item.id,
    jsonb_build_object(
      'store_id', v_item.restaurant_id,
      'is_combo', v_item.is_combo,
      'components', v_components,
      'updated_at_utc', now()
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_combo_component_menu_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.menu_combo_components component
    WHERE component.component_menu_item_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENT_IN_USE';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS prevent_combo_component_menu_delete_trigger
  ON public.menu_items;
CREATE TRIGGER prevent_combo_component_menu_delete_trigger
BEFORE DELETE ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.prevent_combo_component_menu_delete();

CREATE OR REPLACE FUNCTION public.snapshot_order_item_combo_components()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
BEGIN
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'menu_item_id', component_item.id::text,
        'label', component_item.name,
        'quantity', component.quantity
      )
      ORDER BY component.sort_order, component.created_at, component.id
    ),
    '[]'::jsonb
  )
  INTO NEW.combo_components
  FROM public.menu_combo_components component
  JOIN public.menu_items component_item
    ON component_item.id = component.component_menu_item_id
   AND component_item.restaurant_id = component.restaurant_id
  WHERE component.combo_menu_item_id = NEW.menu_item_id
    AND component.restaurant_id = NEW.restaurant_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS snapshot_order_item_combo_components_trigger
  ON public.order_items;
CREATE TRIGGER snapshot_order_item_combo_components_trigger
BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_combo_components();

CREATE OR REPLACE FUNCTION public.enqueue_print_jobs(
  p_order_id uuid,
  p_copy_types text[],
  p_items jsonb,
  p_reason text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_order record;
  v_copy_type text;
  v_batch_no int;
  v_destination_id uuid;
  v_status text;
  v_error text;
  v_items jsonb := '[]'::jsonb;
  v_payload jsonb;
BEGIN
  BEGIN
    IF p_order_id IS NULL THEN
      RAISE EXCEPTION 'PRINT_ORDER_REQUIRED';
    END IF;

    SELECT
      o.id,
      o.restaurant_id,
      o.table_id,
      o.created_at,
      COALESCE(o.notes, '') AS order_notes,
      COALESCE(o.order_purpose, 'customer') AS order_purpose,
      COALESCE(t.table_number, 'STAFF') AS table_number,
      COALESCE(t.floor_label, 'STAFF') AS floor_label
    INTO v_order
    FROM public.orders o
    LEFT JOIN public.tables t ON t.id = o.table_id
    WHERE o.id = p_order_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRINT_ORDER_NOT_FOUND';
    END IF;

    IF jsonb_typeof(COALESCE(p_items, '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'PRINT_ITEMS_INVALID';
    END IF;

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'item_id', NULLIF(item.raw->>'item_id', ''),
          'label', COALESCE(
            NULLIF(item.raw->>'label', ''),
            NULLIF(item.raw->>'name', ''),
            menu_item.name,
            'Item'
          ),
          'qty', COALESCE(
            NULLIF(item.raw->>'quantity', '')::int,
            NULLIF(item.raw->>'qty', '')::int,
            1
          ),
          'notes', NULLIF(item.raw->>'notes', ''),
          'supplemental', COALESCE(
            NULLIF(item.raw->>'supplemental', '')::boolean,
            p_reason = 'added_items'
          ),
          'components', COALESCE(
            CASE
              WHEN jsonb_typeof(item.raw->'components') = 'array'
                THEN item.raw->'components'
              ELSE NULL
            END,
            order_item.combo_components,
            (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'menu_item_id', component_item.id::text,
                  'label', component_item.name,
                  'quantity', component.quantity
                )
                ORDER BY component.sort_order, component.created_at, component.id
              )
              FROM public.menu_combo_components component
              JOIN public.menu_items component_item
                ON component_item.id = component.component_menu_item_id
               AND component_item.restaurant_id = component.restaurant_id
              WHERE component.combo_menu_item_id = menu_item.id
                AND component.restaurant_id = v_order.restaurant_id
            ),
            '[]'::jsonb
          )
        )
        ORDER BY item.ord
      ),
      '[]'::jsonb
    )
    INTO v_items
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
      WITH ORDINALITY AS item(raw, ord)
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = NULLIF(item.raw->>'menu_item_id', '')::uuid
     AND menu_item.restaurant_id = v_order.restaurant_id
    LEFT JOIN LATERAL (
      SELECT candidate.combo_components
      FROM public.order_items candidate
      WHERE candidate.order_id = p_order_id
        AND candidate.restaurant_id = v_order.restaurant_id
        AND (
          candidate.id = NULLIF(item.raw->>'item_id', '')::uuid
          OR (
            NULLIF(item.raw->>'item_id', '') IS NULL
            AND candidate.menu_item_id = menu_item.id
          )
        )
      ORDER BY
        CASE
          WHEN candidate.id = NULLIF(item.raw->>'item_id', '')::uuid THEN 0
          ELSE 1
        END,
        candidate.created_at DESC,
        candidate.id DESC
      LIMIT 1
    ) order_item ON true;

    IF p_reason = 'initial' THEN
      v_batch_no := 1;
    ELSIF p_reason = 'serving' THEN
      SELECT COALESCE(MAX(batch_no), 0) + 1
      INTO v_batch_no
      FROM public.print_jobs
      WHERE order_id = p_order_id
        AND copy_type = 'tray';
    ELSE
      SELECT COALESCE(MAX(batch_no), 1) + 1
      INTO v_batch_no
      FROM public.print_jobs
      WHERE order_id = p_order_id
        AND copy_type IN ('kitchen', 'floor', 'confirmation');
    END IF;

    FOREACH v_copy_type IN ARRAY p_copy_types LOOP
      IF v_copy_type NOT IN ('kitchen', 'floor', 'tray', 'confirmation') THEN
        RAISE EXCEPTION 'PRINT_COPY_TYPE_INVALID';
      END IF;

      v_destination_id := NULL;
      v_status := 'pending';
      v_error := NULL;

      IF v_copy_type IN ('floor', 'confirmation') THEN
        SELECT id INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'floor'
          AND is_active = true
          AND floor_label = v_order.floor_label
        ORDER BY created_at, id
        LIMIT 1;
      ELSIF v_copy_type = 'tray' THEN
        SELECT id INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'tray'
          AND is_active = true
        ORDER BY created_at, id
        LIMIT 1;
      ELSE
        SELECT id INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'kitchen'
          AND is_active = true
        ORDER BY created_at, id
        LIMIT 1;
      END IF;

      IF v_destination_id IS NULL
         AND v_copy_type IN ('floor', 'tray', 'confirmation') THEN
        SELECT id INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'kitchen'
          AND is_active = true
        ORDER BY created_at, id
        LIMIT 1;
      END IF;

      IF v_destination_id IS NULL THEN
        v_status := 'failed';
        v_error := 'NO_DESTINATION';
      END IF;

      v_payload := jsonb_build_object(
        'ticket', v_copy_type,
        'floor_label', v_order.floor_label,
        'table_number', v_order.table_number,
        'ticket_code', substring(v_order.id::text from 1 for 8),
        'batch_no', v_batch_no,
        'printed_reason', p_reason,
        'at', to_char(
          now() AT TIME ZONE 'Asia/Ho_Chi_Minh',
          'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'
        ),
        'items', v_items,
        'order_notes', v_order.order_notes
      );

      IF NOT EXISTS (
        SELECT 1
        FROM public.print_jobs job
        WHERE job.order_id = p_order_id
          AND job.copy_type = v_copy_type
          AND job.batch_no = v_batch_no
          AND (
            job.destination_id = v_destination_id
            OR (job.destination_id IS NULL AND v_destination_id IS NULL)
          )
      ) THEN
        INSERT INTO public.print_jobs(
          restaurant_id,
          order_id,
          copy_type,
          batch_no,
          destination_id,
          payload,
          status,
          last_error
        )
        VALUES (
          v_order.restaurant_id,
          p_order_id,
          v_copy_type,
          v_batch_no,
          v_destination_id,
          v_payload,
          v_status,
          v_error
        );
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'print_enqueue_failed',
      'orders',
      p_order_id,
      jsonb_build_object(
        'copy_types', to_jsonb(p_copy_types),
        'reason', p_reason,
        'error', SQLERRM,
        'created_at_utc', now()
      )
    );
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reorder_menu_categories(uuid, uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reorder_menu_categories(uuid, uuid[])
  TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_menu_combo(uuid, boolean, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_combo(uuid, boolean, jsonb)
  TO authenticated;

REVOKE ALL ON FUNCTION public.enqueue_print_jobs(uuid, text[], jsonb, text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.menu_combo_components IS
  'Store-scoped composition for a sellable combo menu item.';
COMMENT ON COLUMN public.order_items.combo_components IS
  'Immutable combo composition snapshot captured when the order item is created.';
