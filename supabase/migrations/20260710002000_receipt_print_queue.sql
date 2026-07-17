BEGIN;

ALTER TABLE public.printer_destinations
  DROP CONSTRAINT IF EXISTS printer_destinations_purpose_check;

ALTER TABLE public.printer_destinations
  ADD CONSTRAINT printer_destinations_purpose_check
  CHECK (purpose IN ('kitchen', 'floor', 'tray', 'receipt'));

ALTER TABLE public.print_jobs
  DROP CONSTRAINT IF EXISTS print_jobs_copy_type_check;

ALTER TABLE public.print_jobs
  ADD CONSTRAINT print_jobs_copy_type_check
  CHECK (copy_type IN ('kitchen', 'floor', 'tray', 'confirmation', 'receipt'));

CREATE OR REPLACE FUNCTION public.admin_upsert_printer_destination(
  p_store_id uuid,
  p_destination_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_ip text DEFAULT NULL,
  p_port int DEFAULT 9100,
  p_purpose text DEFAULT 'kitchen',
  p_floor_label text DEFAULT NULL,
  p_is_active boolean DEFAULT true
) RETURNS public.printer_destinations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_existing public.printer_destinations%ROWTYPE;
  v_saved public.printer_destinations%ROWTYPE;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_ip text := NULLIF(btrim(COALESCE(p_ip, '')), '');
  v_purpose text := lower(NULLIF(btrim(COALESCE(p_purpose, '')), ''));
  v_floor_label text := NULLIF(btrim(COALESCE(p_floor_label, '')), '');
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'PRINTER_NAME_REQUIRED';
  END IF;

  IF v_ip IS NULL THEN
    RAISE EXCEPTION 'PRINTER_IP_REQUIRED';
  END IF;

  IF p_port IS NULL OR p_port < 1 OR p_port > 65535 THEN
    RAISE EXCEPTION 'PRINTER_PORT_INVALID';
  END IF;

  IF v_purpose IS NULL
     OR v_purpose NOT IN ('kitchen', 'floor', 'tray', 'receipt') THEN
    RAISE EXCEPTION 'PRINTER_PURPOSE_INVALID';
  END IF;

  IF v_purpose = 'floor' AND v_floor_label IS NULL THEN
    RAISE EXCEPTION 'PRINTER_FLOOR_LABEL_REQUIRED';
  END IF;

  IF v_purpose <> 'floor' THEN
    v_floor_label := NULL;
  END IF;

  IF p_destination_id IS NULL THEN
    INSERT INTO public.printer_destinations (
      restaurant_id,
      name,
      ip,
      port,
      purpose,
      floor_label,
      is_active,
      created_at,
      updated_at
    )
    VALUES (
      p_store_id,
      v_name,
      v_ip,
      p_port,
      v_purpose,
      v_floor_label,
      COALESCE(p_is_active, true),
      now(),
      now()
    )
    RETURNING * INTO v_saved;
  ELSE
    SELECT *
    INTO v_existing
    FROM public.printer_destinations
    WHERE id = p_destination_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND';
    END IF;

    IF v_existing.restaurant_id IS DISTINCT FROM p_store_id THEN
      RAISE EXCEPTION 'PRINTER_DESTINATION_STORE_MISMATCH';
    END IF;

    UPDATE public.printer_destinations
    SET name = v_name,
        ip = v_ip,
        port = p_port,
        purpose = v_purpose,
        floor_label = v_floor_label,
        is_active = COALESCE(p_is_active, true),
        updated_at = now()
    WHERE id = p_destination_id
    RETURNING * INTO v_saved;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_upsert_printer_destination',
    'printer_destinations',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'purpose', v_saved.purpose,
      'floor_label', v_saved.floor_label,
      'is_active', v_saved.is_active,
      'updated_at_utc', now()
    )
  );

  RETURN v_saved;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_receipt_print_job(
  p_order_id uuid,
  p_reprint boolean DEFAULT false
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order record;
  v_job public.print_jobs%ROWTYPE;
  v_destination_id uuid;
  v_batch_no int := 1;
  v_status text := 'pending';
  v_error text;
  v_payment_count int;
  v_total_amount numeric(15,2);
  v_payment_method text;
  v_paid_at timestamptz;
  v_is_service boolean;
  v_items jsonb := '[]'::jsonb;
  v_payload jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN
    RAISE EXCEPTION 'RECEIPT_PRINT_FORBIDDEN';
  END IF;

  SELECT
    o.id,
    o.restaurant_id,
    COALESCE(t.table_number, 'STAFF') AS table_number,
    r.name AS restaurant_name
  INTO v_order
  FROM public.orders o
  JOIN public.restaurants r ON r.id = o.restaurant_id
  LEFT JOIN public.tables t ON t.id = o.table_id
  WHERE o.id = p_order_id
  FOR UPDATE OF o;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECEIPT_PRINT_ORDER_NOT_FOUND';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = v_order.restaurant_id
     ) THEN
    RAISE EXCEPTION 'RECEIPT_PRINT_FORBIDDEN';
  END IF;

  IF NOT COALESCE(p_reprint, false) THEN
    SELECT *
    INTO v_job
    FROM public.print_jobs
    WHERE order_id = p_order_id
      AND copy_type = 'receipt'
      AND batch_no = 1
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    IF FOUND THEN
      RETURN v_job;
    END IF;
  END IF;

  SELECT
    count(*)::int,
    ROUND(COALESCE(SUM(COALESCE(p.amount_portion, p.amount)), 0), 2),
    max(p.created_at),
    bool_and(NOT COALESCE(p.is_revenue, true))
  INTO
    v_payment_count,
    v_total_amount,
    v_paid_at,
    v_is_service
  FROM public.payments p
  WHERE p.order_id = p_order_id
    AND p.restaurant_id = v_order.restaurant_id;

  IF v_payment_count = 0 THEN
    RAISE EXCEPTION 'RECEIPT_PRINT_PAYMENT_REQUIRED';
  END IF;

  IF v_is_service THEN
    v_payment_method := 'SERVICE';
  ELSIF v_payment_count > 1 THEN
    v_payment_method := 'SPLIT';
  ELSE
    SELECT upper(COALESCE(p.method, 'OTHER'))
    INTO v_payment_method
    FROM public.payments p
    WHERE p.order_id = p_order_id
      AND p.restaurant_id = v_order.restaurant_id
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'label', COALESCE(NULLIF(oi.label, ''), NULLIF(oi.display_name, ''), 'Item'),
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'is_service_item', COALESCE(oi.is_service_item, false)
      )
      ORDER BY oi.created_at, oi.id
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.status <> 'cancelled';

  IF COALESCE(p_reprint, false) THEN
    SELECT COALESCE(MAX(batch_no), 0) + 1
    INTO v_batch_no
    FROM public.print_jobs
    WHERE order_id = p_order_id
      AND copy_type = 'receipt';
  END IF;

  SELECT id
  INTO v_destination_id
  FROM public.printer_destinations
  WHERE restaurant_id = v_order.restaurant_id
    AND purpose = 'receipt'
    AND is_active = true
  ORDER BY created_at, id
  LIMIT 1;

  IF v_destination_id IS NULL THEN
    v_status := 'failed';
    v_error := 'NO_DESTINATION';
  END IF;

  v_payload := jsonb_build_object(
    'ticket', 'receipt',
    'restaurant_name', v_order.restaurant_name,
    'table_number', v_order.table_number,
    'ticket_code', substring(v_order.id::text from 1 for 8),
    'batch_no', v_batch_no,
    'printed_reason', CASE
      WHEN COALESCE(p_reprint, false) THEN 'reprint'
      ELSE 'payment'
    END,
    'at', to_char(
      v_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
      'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'
    ),
    'items', v_items,
    'total_amount', v_total_amount,
    'payment_method', v_payment_method,
    'is_service', v_is_service
  );

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
    'receipt',
    v_batch_no,
    v_destination_id,
    v_payload,
    v_status,
    v_error
  )
  RETURNING * INTO v_job;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'enqueue_receipt_print_job',
    'print_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', v_order.restaurant_id,
      'order_id', p_order_id,
      'batch_no', v_batch_no,
      'reprint', COALESCE(p_reprint, false),
      'status', v_status,
      'updated_at_utc', now()
    )
  );

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_enqueue_printer_test_job(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_destination public.printer_destinations%ROWTYPE;
  v_job public.print_jobs%ROWTYPE;
  v_ticket text;
  v_floor_label text;
  v_store_name text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT *
  INTO v_destination
  FROM public.printer_destinations
  WHERE id = p_destination_id
    AND restaurant_id = p_store_id
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND';
  END IF;

  SELECT name INTO v_store_name
  FROM public.restaurants
  WHERE id = p_store_id;

  v_ticket := v_destination.purpose;
  v_floor_label := COALESCE(NULLIF(v_destination.floor_label, ''), 'TEST');

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
    p_store_id,
    NULL,
    v_ticket,
    1,
    v_destination.id,
    jsonb_build_object(
      'ticket', v_ticket,
      'restaurant_name', COALESCE(v_store_name, 'GLOBOS POS'),
      'floor_label', v_floor_label,
      'table_number', v_destination.name,
      'ticket_code', 'TEST',
      'batch_no', 1,
      'printed_reason', 'test_print',
      'at', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'),
      'items', jsonb_build_array(
        jsonb_build_object(
          'label', 'Printer route test',
          'qty', 1,
          'quantity', 1,
          'unit_price', 1000,
          'is_service_item', false,
          'notes', NULL,
          'supplemental', false
        )
      ),
      'total_amount', 1000,
      'payment_method', 'CASH',
      'is_service', false,
      'order_notes', 'Print destination test'
    ),
    'pending',
    NULL
  )
  RETURNING * INTO v_job;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_enqueue_printer_test_job',
    'print_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'destination_id', v_destination.id,
      'purpose', v_destination.purpose,
      'updated_at_utc', now()
    )
  );

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
  v_error text;
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

  IF v_source.copy_type IN ('floor', 'confirmation') THEN
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
  ELSIF v_source.copy_type = 'receipt' THEN
    SELECT id
    INTO v_destination_id
    FROM public.printer_destinations
    WHERE restaurant_id = v_source.restaurant_id
      AND purpose = 'receipt'
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

  IF v_destination_id IS NULL
     AND v_source.copy_type IN ('floor', 'tray', 'confirmation') THEN
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

  v_payload := jsonb_set(
    v_source.payload,
    '{printed_reason}',
    to_jsonb('reprint'::text),
    true
  );
  v_payload := jsonb_set(v_payload, '{batch_no}', to_jsonb(v_batch_no), true);
  v_payload := jsonb_set(
    v_payload,
    '{reprint_of}',
    to_jsonb(v_source.id::text),
    true
  );

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

REVOKE ALL ON FUNCTION public.enqueue_receipt_print_job(uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_receipt_print_job(uuid, boolean)
  TO authenticated, service_role;

COMMIT;
