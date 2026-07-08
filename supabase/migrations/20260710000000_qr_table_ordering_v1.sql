-- QR Table Ordering V1.
-- Anonymous guests can scan a per-table token, view public menu items, and
-- place cashier-pay-later orders. Payment remains POS/cashier-only.

BEGIN;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS order_source text NOT NULL DEFAULT 'staff';

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_order_source_check;

ALTER TABLE public.orders
  ADD CONSTRAINT orders_order_source_check
  CHECK (order_source IN ('staff', 'qr'));

CREATE TABLE IF NOT EXISTS public.table_qr_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  table_id uuid NOT NULL REFERENCES public.tables(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  rotated_at timestamptz,
  CONSTRAINT table_qr_tokens_token_present CHECK (btrim(token) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS table_qr_tokens_one_active
  ON public.table_qr_tokens(table_id)
  WHERE is_active;

CREATE INDEX IF NOT EXISTS table_qr_tokens_store_table
  ON public.table_qr_tokens(restaurant_id, table_id);

CREATE TABLE IF NOT EXISTS public.qr_order_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  table_id uuid NOT NULL REFERENCES public.tables(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  batch_no int NOT NULL CHECK (batch_no > 0),
  client_order_id uuid NOT NULL UNIQUE,
  items_snapshot jsonb NOT NULL,
  result_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS qr_order_batches_table_created
  ON public.qr_order_batches(table_id, created_at DESC);

ALTER TABLE public.table_qr_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qr_order_batches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS table_qr_tokens_admin_read
  ON public.table_qr_tokens;
CREATE POLICY table_qr_tokens_admin_read
  ON public.table_qr_tokens
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      JOIN public.users u ON u.auth_id = auth.uid()
      WHERE s.store_id = table_qr_tokens.restaurant_id
        AND u.is_active = true
        AND u.role IN ('admin', 'store_admin', 'super_admin')
    )
  );

DROP POLICY IF EXISTS qr_order_batches_store_read
  ON public.qr_order_batches;
CREATE POLICY qr_order_batches_store_read
  ON public.qr_order_batches
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = qr_order_batches.restaurant_id
    )
  );

REVOKE ALL ON public.table_qr_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.qr_order_batches FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.table_qr_tokens TO authenticated;
GRANT SELECT ON public.qr_order_batches TO authenticated;
GRANT ALL ON public.table_qr_tokens TO service_role;
GRANT ALL ON public.qr_order_batches TO service_role;

ALTER TABLE public.print_jobs
  DROP CONSTRAINT IF EXISTS print_jobs_copy_type_check;

ALTER TABLE public.print_jobs
  ADD CONSTRAINT print_jobs_copy_type_check
  CHECK (copy_type IN ('kitchen', 'floor', 'tray', 'confirmation'));

CREATE OR REPLACE FUNCTION public.admin_generate_table_qr(
  p_table_id uuid
) RETURNS public.table_qr_tokens
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_table public.tables%ROWTYPE;
  v_saved public.table_qr_tokens%ROWTYPE;
  v_token text;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_table.restaurant_id);

  UPDATE public.table_qr_tokens
  SET is_active = false,
      rotated_at = now()
  WHERE table_id = p_table_id
    AND is_active = true;

  v_token := replace(
    replace(
      rtrim(encode(extensions.gen_random_bytes(24), 'base64'), '='),
      '+',
      '-'
    ),
    '/',
    '_'
  );

  INSERT INTO public.table_qr_tokens (
    restaurant_id,
    table_id,
    token,
    created_by
  )
  VALUES (
    v_table.restaurant_id,
    v_table.id,
    v_token,
    auth.uid()
  )
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qr_token_rotated',
    'tables',
    v_table.id,
    jsonb_build_object(
      'store_id', v_table.restaurant_id,
      'qr_token_id', v_saved.id
    )
  );

  RETURN v_saved;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_get_menu(
  p_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT
    q.restaurant_id,
    q.table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id
   AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id
   AND r.is_active = true
  WHERE q.token = v_token
    AND q.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id::text,
        'name', c.name,
        'sort_order', c.sort_order
      )
      ORDER BY c.sort_order, c.name, c.id
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM public.menu_categories c
  WHERE c.restaurant_id = v_table.restaurant_id
    AND c.is_active = true
    AND EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.restaurant_id = c.restaurant_id
        AND mi.category_id = c.id
        AND mi.is_available = true
        AND mi.is_visible_public = true
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', mi.id::text,
        'category_id', mi.category_id::text,
        'name', mi.name,
        'description', mi.description,
        'price', mi.price
      )
      ORDER BY COALESCE(mc.sort_order, 0), mi.sort_order, mi.name, mi.id
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.menu_items mi
  LEFT JOIN public.menu_categories mc
    ON mc.id = mi.category_id
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
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_print_jobs(
  p_order_id uuid,
  p_copy_types text[],
  p_items jsonb,
  p_reason text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
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
          'label', COALESCE(NULLIF(item.raw->>'label', ''), NULLIF(item.raw->>'name', ''), m.name, 'Item'),
          'qty', COALESCE(NULLIF(item.raw->>'quantity', '')::int, NULLIF(item.raw->>'qty', '')::int, 1),
          'notes', NULLIF(item.raw->>'notes', ''),
          'supplemental', COALESCE(NULLIF(item.raw->>'supplemental', '')::boolean, p_reason = 'added_items')
        )
        ORDER BY item.ord
      ),
      '[]'::jsonb
    )
    INTO v_items
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) WITH ORDINALITY AS item(raw, ord)
    LEFT JOIN public.menu_items m
      ON m.id = NULLIF(item.raw->>'menu_item_id', '')::uuid
     AND m.restaurant_id = v_order.restaurant_id;

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
        SELECT id
        INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'floor'
          AND is_active = true
          AND floor_label = v_order.floor_label
        ORDER BY created_at, id
        LIMIT 1;
      ELSIF v_copy_type = 'tray' THEN
        SELECT id
        INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'tray'
          AND is_active = true
        ORDER BY created_at, id
        LIMIT 1;
      ELSE
        SELECT id
        INTO v_destination_id
        FROM public.printer_destinations
        WHERE restaurant_id = v_order.restaurant_id
          AND purpose = 'kitchen'
          AND is_active = true
        ORDER BY created_at, id
        LIMIT 1;
      END IF;

      IF v_destination_id IS NULL AND v_copy_type IN ('floor', 'tray', 'confirmation') THEN
        SELECT id
        INTO v_destination_id
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
        'at', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'),
        'items', v_items,
        'order_notes', v_order.order_notes
      );

      IF NOT EXISTS (
        SELECT 1
        FROM public.print_jobs pj
        WHERE pj.order_id = p_order_id
          AND pj.copy_type = v_copy_type
          AND pj.batch_no = v_batch_no
          AND (
            pj.destination_id = v_destination_id
            OR (pj.destination_id IS NULL AND v_destination_id IS NULL)
          )
      ) THEN
        INSERT INTO public.print_jobs (
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
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
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

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_existing_batch public.qr_order_batches%ROWTYPE;
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_item_count int;
  v_line record;
  v_live_order public.orders%ROWTYPE;
  v_order_id uuid;
  v_is_new_order boolean := false;
  v_batch_no int;
  v_items_snapshot jsonb := '[]'::jsonb;
  v_result jsonb;
  v_print_reason text;
BEGIN
  IF p_client_order_id IS NULL THEN
    RAISE EXCEPTION 'QR_CLIENT_ORDER_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing_batch
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id;

  IF FOUND THEN
    RETURN v_existing_batch.result_snapshot;
  END IF;

  SELECT
    q.restaurant_id,
    q.table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id
   AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id
   AND r.is_active = true
  WHERE q.token = v_token
    AND q.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  IF jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  v_item_count := jsonb_array_length(v_items);
  IF v_item_count < 1 OR v_item_count > 20 THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  FOR v_line IN
    SELECT raw
    FROM jsonb_array_elements(v_items) AS line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
    IF COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$'
       OR (v_line.raw->>'quantity')::int < 1
       OR (v_line.raw->>'quantity')::int > 20 THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.qr_order_batches b
    WHERE b.table_id = v_table.table_id
      AND b.created_at > now() - interval '20 seconds'
  ) THEN
    RAISE EXCEPTION 'QR_TOO_FREQUENT';
  END IF;

  WITH input_items AS (
    SELECT
      (raw->>'menu_item_id')::uuid AS menu_item_id,
      (raw->>'quantity')::int AS quantity,
      ord
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS line(raw, ord)
  ),
  matched_items AS (
    SELECT
      i.menu_item_id,
      i.quantity,
      i.ord,
      m.name,
      m.price
    FROM input_items i
    JOIN public.menu_items m
      ON m.id = i.menu_item_id
     AND m.restaurant_id = v_table.restaurant_id
     AND m.is_available = true
     AND m.is_visible_public = true
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'menu_item_id', menu_item_id::text,
        'quantity', quantity,
        'name', name,
        'unit_price', price
      )
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_items_snapshot
  FROM matched_items;

  IF jsonb_array_length(v_items_snapshot) <> v_item_count THEN
    RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  END IF;

  PERFORM 1
  FROM public.tables
  WHERE id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
  FOR UPDATE;

  SELECT *
  INTO v_live_order
  FROM public.orders
  WHERE table_id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
    AND status IN ('pending', 'confirmed', 'serving')
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.orders (
      restaurant_id,
      table_id,
      sales_channel,
      status,
      created_by,
      order_source,
      order_purpose
    )
    VALUES (
      v_table.restaurant_id,
      v_table.table_id,
      'dine_in',
      'pending',
      NULL,
      'qr',
      'customer'
    )
    RETURNING * INTO v_live_order;

    v_is_new_order := true;

    UPDATE public.tables
    SET status = 'occupied',
        updated_at = now()
    WHERE id = v_table.table_id;
  ELSE
    IF EXISTS (
      SELECT 1
      FROM public.payments p
      WHERE p.order_id = v_live_order.id
    ) THEN
      RAISE EXCEPTION 'QR_ORDER_PAYMENT_IN_PROGRESS';
    END IF;
  END IF;

  v_order_id := v_live_order.id;

  INSERT INTO public.order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type
  )
  SELECT
    v_order_id,
    m.id,
    (item.raw->>'quantity')::int,
    m.price,
    m.name,
    m.name,
    v_table.restaurant_id,
    'menu_item'
  FROM jsonb_array_elements(v_items) WITH ORDINALITY AS item(raw, ord)
  JOIN public.menu_items m
    ON m.id = (item.raw->>'menu_item_id')::uuid
   AND m.restaurant_id = v_table.restaurant_id
   AND m.is_available = true
   AND m.is_visible_public = true
  ORDER BY item.ord;

  IF NOT v_is_new_order THEN
    PERFORM public.void_active_order_discount_for_item_change(
      v_order_id,
      v_table.restaurant_id,
      'order_items_changed'
    );
  END IF;

  PERFORM public.recalc_order_status(v_order_id);

  SELECT COALESCE(MAX(batch_no), 0) + 1
  INTO v_batch_no
  FROM public.print_jobs
  WHERE order_id = v_order_id
    AND copy_type IN ('kitchen', 'floor', 'confirmation');

  v_print_reason := CASE WHEN v_batch_no = 1 THEN 'initial' ELSE 'added_items' END;

  PERFORM public.enqueue_print_jobs(
    v_order_id,
    ARRAY['kitchen', 'floor', 'confirmation'],
    v_items,
    v_print_reason
  );

  v_result := jsonb_build_object(
    'order_id', v_order_id::text,
    'order_code', substring(v_order_id::text from 1 for 8),
    'batch_no', v_batch_no,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'items', (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'name', item->>'name',
            'quantity', (item->>'quantity')::int
          )
        ),
        '[]'::jsonb
      )
      FROM jsonb_array_elements(v_items_snapshot) item
    )
  );

  INSERT INTO public.qr_order_batches (
    restaurant_id,
    table_id,
    order_id,
    batch_no,
    client_order_id,
    items_snapshot,
    result_snapshot
  )
  VALUES (
    v_table.restaurant_id,
    v_table.table_id,
    v_order_id,
    v_batch_no,
    p_client_order_id,
    v_items_snapshot,
    v_result
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    NULL,
    'qr_place_order',
    'orders',
    v_order_id,
    jsonb_build_object(
      'store_id', v_table.restaurant_id,
      'table_id', v_table.table_id,
      'batch_no', v_batch_no,
      'client_order_id', p_client_order_id,
      'item_count', v_item_count
    )
  );

  RETURN v_result;
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_existing_batch
    FROM public.qr_order_batches
    WHERE client_order_id = p_client_order_id;
    IF FOUND THEN
      RETURN v_existing_batch.result_snapshot;
    END IF;
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_generate_table_qr(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_get_menu(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_generate_table_qr(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.qr_get_menu(text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.qr_place_order(text, jsonb, uuid)
  TO anon, authenticated, service_role;

COMMIT;
