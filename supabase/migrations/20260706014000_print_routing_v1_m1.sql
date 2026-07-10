BEGIN;

-- Floor/Station Print Routing V1 M1.
-- DB queue first: web clients never talk to LAN printers. A native print
-- station claims these rows and prints on the store LAN.

ALTER TABLE public.tables
  ADD COLUMN IF NOT EXISTS floor_label text NOT NULL DEFAULT '1F';

COMMENT ON COLUMN public.tables.floor_label IS
  'Service floor/area label used by print routing, e.g. 1F, 2F, 3F.';

CREATE TABLE IF NOT EXISTS public.printer_destinations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name text NOT NULL,
  ip text NOT NULL,
  port int NOT NULL DEFAULT 9100,
  purpose text NOT NULL CHECK (purpose IN ('kitchen', 'floor', 'tray')),
  floor_label text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT printer_destinations_name_present CHECK (btrim(name) <> ''),
  CONSTRAINT printer_destinations_ip_present CHECK (btrim(ip) <> ''),
  CONSTRAINT printer_destinations_port_range CHECK (port BETWEEN 1 AND 65535),
  CONSTRAINT floor_purpose_needs_label
    CHECK (purpose <> 'floor' OR NULLIF(btrim(COALESCE(floor_label, '')), '') IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS printer_destinations_store_purpose
  ON public.printer_destinations (restaurant_id, purpose, floor_label)
  WHERE is_active = true;

ALTER TABLE public.printer_destinations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS printer_destinations_store_read
  ON public.printer_destinations;
CREATE POLICY printer_destinations_store_read
  ON public.printer_destinations
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = printer_destinations.restaurant_id
    )
  );

CREATE TABLE IF NOT EXISTS public.print_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  copy_type text NOT NULL CHECK (copy_type IN ('kitchen', 'floor', 'tray')),
  batch_no int NOT NULL CHECK (batch_no > 0),
  destination_id uuid REFERENCES public.printer_destinations(id),
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'printing', 'done', 'failed', 'cancelled')),
  attempts int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error text,
  next_retry_at timestamptz NOT NULL DEFAULT now(),
  claimed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT print_jobs_idempotent
    UNIQUE (order_id, copy_type, batch_no, destination_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS print_jobs_idempotent_missing_destination
  ON public.print_jobs (order_id, copy_type, batch_no)
  WHERE destination_id IS NULL;

CREATE INDEX IF NOT EXISTS print_jobs_pending
  ON public.print_jobs (restaurant_id, status, next_retry_at)
  WHERE status IN ('pending', 'failed');

CREATE INDEX IF NOT EXISTS print_jobs_order_created
  ON public.print_jobs (order_id, created_at DESC);

ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS print_jobs_store_read
  ON public.print_jobs;
CREATE POLICY print_jobs_store_read
  ON public.print_jobs
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = print_jobs.restaurant_id
    )
  );

REVOKE ALL ON public.printer_destinations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.print_jobs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.printer_destinations TO authenticated;
GRANT SELECT ON public.print_jobs TO authenticated;
GRANT ALL ON public.printer_destinations TO service_role;
GRANT ALL ON public.print_jobs TO service_role;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'print_jobs'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.print_jobs';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.print_routing_actor_can_run(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('kitchen', 'admin', 'store_admin', 'super_admin')
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = p_store_id
        )
      )
  );
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

    -- One operational event must produce one batch number across every copy
    -- created by that event. For example, add-items batch 2 prints both the
    -- kitchen and floor tickets as batch 2.
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
        AND copy_type IN ('kitchen', 'floor');
    END IF;

    FOREACH v_copy_type IN ARRAY p_copy_types LOOP
      IF v_copy_type NOT IN ('kitchen', 'floor', 'tray') THEN
        RAISE EXCEPTION 'PRINT_COPY_TYPE_INVALID';
      END IF;

      v_destination_id := NULL;
      v_status := 'pending';
      v_error := NULL;

      IF v_copy_type = 'floor' THEN
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

      IF v_destination_id IS NULL AND v_copy_type IN ('floor', 'tray') THEN
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

CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_table_id uuid,
  p_items jsonb
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_table public.tables%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM public.tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_NOT_AVAILABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders (restaurant_id, table_id, status, created_by)
  VALUES (p_store_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

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
    v_order.id,
    m.id,
    (item->>'quantity')::int,
    m.price,
    m.name,
    m.name,
    p_store_id,
    'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE public.tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  PERFORM public.enqueue_print_jobs(
    v_order.id,
    ARRAY['kitchen', 'floor'],
    p_items,
    'initial'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.recalc_order_status(
  p_order_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_active int;
  v_done int;
  v_started int;
  v_next text;
  v_tray_items jsonb := '[]'::jsonb;
  v_tray_batch_no int := 1;
BEGIN
  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RETURN;
  END IF;

  SELECT
    count(*) FILTER (WHERE status <> 'cancelled'),
    count(*) FILTER (WHERE status IN ('ready', 'served')),
    count(*) FILTER (WHERE status IN ('preparing', 'ready', 'served'))
  INTO v_active, v_done, v_started
  FROM public.order_items
  WHERE order_id = p_order_id;

  IF v_active = 0 THEN
    v_next := 'cancelled';
  ELSIF v_done = v_active THEN
    v_next := 'serving';
  ELSIF v_started > 0 THEN
    v_next := 'confirmed';
  ELSE
    v_next := 'pending';
  END IF;

  IF v_next = v_order.status THEN
    UPDATE public.orders SET updated_at = now() WHERE id = p_order_id;
    RETURN;
  END IF;

  UPDATE public.orders
  SET status = v_next,
      updated_at = now()
  WHERE id = p_order_id;

  IF v_next = 'cancelled' AND v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'recalc_order_status',
    'orders',
    p_order_id,
    jsonb_build_object(
      'from_status', v_order.status,
      'to_status', v_next
    )
  );

  IF v_next = 'serving' AND v_order.status <> 'serving' THEN
    SELECT COALESCE(MAX(batch_no), 0) + 1
    INTO v_tray_batch_no
    FROM public.print_jobs
    WHERE order_id = p_order_id
      AND copy_type = 'tray';

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'item_id', oi.id::text,
          'label', COALESCE(NULLIF(oi.label, ''), NULLIF(oi.display_name, ''), 'Item'),
          'quantity', oi.quantity,
          'notes', oi.notes,
          'supplemental', v_tray_batch_no > 1 OR oi.created_at > v_order.created_at + interval '10 seconds'
        )
        ORDER BY oi.created_at, oi.id
      ),
      '[]'::jsonb
    )
    INTO v_tray_items
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND (
        v_tray_batch_no = 1
        OR NOT EXISTS (
          SELECT 1
          FROM public.print_jobs prior
          CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(prior.payload->'items', '[]'::jsonb)
          ) AS prior_item(raw)
          WHERE prior.order_id = p_order_id
            AND prior.copy_type = 'tray'
            AND prior.status <> 'cancelled'
            AND NULLIF(prior_item.raw->>'item_id', '') = oi.id::text
        )
      );

    IF jsonb_array_length(v_tray_items) > 0 THEN
      PERFORM public.enqueue_print_jobs(
        p_order_id,
        ARRAY['tray'],
        v_tray_items,
        'serving'
      );
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_inserted_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO public.order_items (
    order_id, menu_item_id, quantity, unit_price,
    label, display_name, restaurant_id, item_type
  )
  SELECT
    p_order_id, m.id, (item->>'quantity')::int, m.price,
    m.name, m.name, p_store_id, 'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  PERFORM public.recalc_order_status(p_order_id);
  PERFORM public.void_active_order_discount_for_item_change(p_order_id, p_store_id, 'order_items_changed');
  PERFORM public.enqueue_print_jobs(
    p_order_id,
    ARRAY['kitchen', 'floor'],
    p_items,
    'added_items'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$;

DROP FUNCTION IF EXISTS public.cancel_order(uuid, uuid);

CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid,
  p_allow_served boolean DEFAULT false
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_from_status text;
  v_cancelled_items int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  IF v_order.status = 'serving'
     AND v_actor.role NOT IN ('admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_SERVING_CANCEL_ADMIN_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items
    WHERE order_id = p_order_id
      AND status = 'served'
  ) AND NOT COALESCE(p_allow_served, false) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_ITEMS';
  END IF;

  v_from_status := v_order.status;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE order_id = p_order_id
    AND status IN ('pending', 'preparing', 'ready');
  GET DIAGNOSTICS v_cancelled_items = ROW_COUNT;

  UPDATE public.orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE public.print_jobs
  SET status = 'cancelled',
      updated_at = now()
  WHERE order_id = p_order_id
    AND status IN ('pending', 'failed');

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'cancelled_item_count', v_cancelled_items
    )
  );

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_print_jobs(
  p_store_id uuid,
  p_limit int DEFAULT 10
) RETURNS SETOF public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF NOT public.print_routing_actor_can_run(p_store_id) THEN
    RAISE EXCEPTION 'PRINT_CLAIM_FORBIDDEN';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT id
    FROM public.print_jobs
    WHERE restaurant_id = p_store_id
      AND status IN ('pending', 'failed')
      AND destination_id IS NOT NULL
      AND next_retry_at <= now()
      AND attempts < 10
    ORDER BY created_at, id
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.print_jobs pj
  SET status = 'printing',
      claimed_by = auth.uid(),
      attempts = attempts + 1,
      updated_at = now()
  FROM candidates c
  WHERE pj.id = c.id
  RETURNING pj.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_print_job(
  p_job_id uuid,
  p_ok boolean,
  p_error text DEFAULT NULL
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_job public.print_jobs%ROWTYPE;
BEGIN
  SELECT *
  INTO v_job
  FROM public.print_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINT_JOB_NOT_FOUND';
  END IF;

  IF NOT public.print_routing_actor_can_run(v_job.restaurant_id) THEN
    RAISE EXCEPTION 'PRINT_COMPLETE_FORBIDDEN';
  END IF;

  IF COALESCE(p_ok, false) THEN
    UPDATE public.print_jobs
    SET status = 'done',
        last_error = NULL,
        updated_at = now()
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  ELSE
    UPDATE public.print_jobs
    SET status = 'failed',
        last_error = COALESCE(NULLIF(btrim(COALESCE(p_error, '')), ''), 'PRINT_FAILED'),
        next_retry_at = now() + make_interval(secs => LEAST(GREATEST(attempts, 1), 5) * 20),
        updated_at = now()
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  END IF;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.reprint_print_job(
  p_job_id uuid
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_source public.print_jobs%ROWTYPE;
  v_order record;
  v_destination_id uuid;
  v_status text := 'pending';
  v_error text := NULL;
  v_batch_no int;
  v_payload jsonb;
  v_created public.print_jobs%ROWTYPE;
BEGIN
  SELECT *
  INTO v_source
  FROM public.print_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINT_JOB_NOT_FOUND';
  END IF;

  IF NOT public.print_routing_actor_can_run(v_source.restaurant_id) THEN
    RAISE EXCEPTION 'PRINT_REPRINT_FORBIDDEN';
  END IF;

  SELECT
    o.id,
    o.restaurant_id,
    COALESCE(t.floor_label, 'STAFF') AS floor_label
  INTO v_order
  FROM public.orders o
  LEFT JOIN public.tables t ON t.id = o.table_id
  WHERE o.id = v_source.order_id
    AND o.restaurant_id = v_source.restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINT_ORDER_NOT_FOUND';
  END IF;

  SELECT COALESCE(MAX(batch_no), 0) + 1
  INTO v_batch_no
  FROM public.print_jobs
  WHERE order_id = v_source.order_id
    AND copy_type = v_source.copy_type;

  IF v_source.copy_type = 'floor' THEN
    SELECT id
    INTO v_destination_id
    FROM public.printer_destinations
    WHERE restaurant_id = v_source.restaurant_id
      AND purpose = 'floor'
      AND floor_label = v_order.floor_label
      AND is_active = true
    ORDER BY created_at, id
    LIMIT 1;
  ELSIF v_source.copy_type = 'tray' THEN
    SELECT id
    INTO v_destination_id
    FROM public.printer_destinations
    WHERE restaurant_id = v_source.restaurant_id
      AND purpose = 'tray'
      AND is_active = true
    ORDER BY created_at, id
    LIMIT 1;
  ELSE
    SELECT id
    INTO v_destination_id
    FROM public.printer_destinations
    WHERE restaurant_id = v_source.restaurant_id
      AND purpose = 'kitchen'
      AND is_active = true
    ORDER BY created_at, id
    LIMIT 1;
  END IF;

  IF v_destination_id IS NULL AND v_source.copy_type IN ('floor', 'tray') THEN
    SELECT id
    INTO v_destination_id
    FROM public.printer_destinations
    WHERE restaurant_id = v_source.restaurant_id
      AND purpose = 'kitchen'
      AND is_active = true
    ORDER BY created_at, id
    LIMIT 1;
  END IF;

  IF v_destination_id IS NULL THEN
    v_status := 'failed';
    v_error := 'NO_DESTINATION';
  END IF;

  v_payload := jsonb_set(v_source.payload, '{printed_reason}', to_jsonb('reprint'::text), true);
  v_payload := jsonb_set(v_payload, '{batch_no}', to_jsonb(v_batch_no), true);
  v_payload := jsonb_set(v_payload, '{reprint_of}', to_jsonb(v_source.id::text), true);

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
    v_source.restaurant_id,
    v_source.order_id,
    v_source.copy_type,
    v_batch_no,
    v_destination_id,
    v_payload,
    v_status,
    v_error
  )
  RETURNING * INTO v_created;

  RETURN v_created;
END;
$$;

REVOKE ALL ON FUNCTION public.print_routing_actor_can_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enqueue_print_jobs(uuid, text[], jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.claim_print_jobs(uuid, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_print_job(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reprint_print_job(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_print_jobs(uuid, int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_print_job(uuid, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reprint_print_job(uuid) TO authenticated, service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'print-jobs-retention-daily') THEN
      PERFORM cron.unschedule('print-jobs-retention-daily');
    END IF;

    PERFORM cron.schedule(
      'print-jobs-retention-daily',
      '17 17 * * *',
      $inner$
      DELETE FROM public.print_jobs
      WHERE status IN ('done', 'cancelled')
        AND updated_at < now() - interval '7 days';
      $inner$
    );
  ELSE
    RAISE NOTICE 'pg_cron is unavailable; skipped print job retention schedule.';
  END IF;
END;
$$;

COMMIT;
