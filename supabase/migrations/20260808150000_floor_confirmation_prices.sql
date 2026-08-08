-- Preserve immutable prices in floor confirmation payloads. Added-order kitchen
-- jobs keep the inserted-row delta, while floor and confirmation jobs receive the
-- complete active order. Routing, batching, combo snapshots, and best-effort queue
-- semantics remain unchanged.

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
  v_full_items jsonb := '[]'::jsonb;
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
          'unit_price', COALESCE(
            NULLIF(item.raw->>'unit_price', '')::numeric,
            order_item.unit_price,
            menu_item.price
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
      SELECT candidate.combo_components, candidate.unit_price
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

    IF p_reason = 'added_items' THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'item_id', order_item.id::text,
            'label', COALESCE(
              NULLIF(order_item.label, ''),
              NULLIF(order_item.display_name, ''),
              menu_item.name,
              'Item'
            ),
            'qty', order_item.quantity,
            'unit_price', order_item.unit_price,
            'notes', NULLIF(order_item.notes, ''),
            'supplemental', EXISTS (
              SELECT 1
              FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) delta(raw)
              WHERE NULLIF(delta.raw->>'item_id', '')::uuid = order_item.id
            ),
            'components', COALESCE(order_item.combo_components, '[]'::jsonb)
          )
          ORDER BY order_item.created_at, order_item.id
        ),
        '[]'::jsonb
      )
      INTO v_full_items
      FROM public.order_items order_item
      LEFT JOIN public.menu_items menu_item
        ON menu_item.id = order_item.menu_item_id
       AND menu_item.restaurant_id = order_item.restaurant_id
      WHERE order_item.order_id = p_order_id
        AND order_item.restaurant_id = v_order.restaurant_id
        AND order_item.status <> 'cancelled';
    END IF;

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
        'items', CASE
          WHEN p_reason = 'added_items'
           AND v_copy_type IN ('floor', 'confirmation')
            THEN v_full_items
          ELSE v_items
        END,
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

REVOKE ALL ON FUNCTION public.enqueue_print_jobs(uuid, text[], jsonb, text)
  FROM PUBLIC, anon, authenticated;
