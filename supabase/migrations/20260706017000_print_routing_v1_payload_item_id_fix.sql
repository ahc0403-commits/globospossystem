-- Preserve order item identity in print payloads for tray delta detection.

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

REVOKE ALL ON FUNCTION public.enqueue_print_jobs(uuid, text[], jsonb, text)
  FROM PUBLIC, anon, authenticated;
