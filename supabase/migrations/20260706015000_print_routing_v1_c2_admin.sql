BEGIN;

-- Print Routing V1 C2: admin configuration surface.
-- Keep printer destinations RPC-only for writes, and carry table floor labels
-- through the existing table admin/audit boundary.

DROP FUNCTION IF EXISTS public.admin_create_table(uuid, text, int);

CREATE OR REPLACE FUNCTION public.admin_create_table(
  p_store_id uuid,
  p_table_number text,
  p_seat_count int,
  p_floor_label text DEFAULT '1F'
) RETURNS public.tables
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_created public.tables%ROWTYPE;
  v_next_sort_order int;
  v_next_x numeric(6,4);
  v_next_y numeric(6,4);
  v_floor_label text := NULLIF(btrim(COALESCE(p_floor_label, '')), '');
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  IF v_floor_label IS NULL THEN
    RAISE EXCEPTION 'TABLE_FLOOR_LABEL_REQUIRED';
  END IF;

  SELECT COALESCE(MAX(layout_sort_order), -1) + 1
  INTO v_next_sort_order
  FROM public.tables
  WHERE restaurant_id = p_store_id;

  v_next_x := ((v_next_sort_order % 4) * 0.22)::numeric(6,4);
  v_next_y := (LEAST((v_next_sort_order / 4) * 0.18, 0.86))::numeric(6,4);

  INSERT INTO public.tables (
    restaurant_id,
    table_number,
    seat_count,
    status,
    floor_label,
    layout_x,
    layout_y,
    layout_w,
    layout_h,
    layout_rotation,
    layout_shape,
    layout_sort_order,
    created_at,
    updated_at
  )
  VALUES (
    p_store_id,
    btrim(p_table_number),
    p_seat_count,
    'available',
    v_floor_label,
    v_next_x,
    v_next_y,
    0.18,
    0.14,
    0,
    'rectangle',
    v_next_sort_order,
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_table',
    'tables',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'table_number', v_created.table_number,
        'seat_count', v_created.seat_count,
        'status', v_created.status,
        'floor_label', v_created.floor_label,
        'layout_x', v_created.layout_x,
        'layout_y', v_created.layout_y,
        'layout_w', v_created.layout_w,
        'layout_h', v_created.layout_h,
        'layout_rotation', v_created.layout_rotation,
        'layout_shape', v_created.layout_shape,
        'layout_sort_order', v_created.layout_sort_order
      )
    )
  );

  RETURN v_created;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_update_table(
  uuid,
  uuid,
  text,
  int,
  text,
  numeric,
  numeric,
  numeric,
  numeric,
  int,
  text,
  int
);

CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id uuid,
  p_store_id uuid,
  p_table_number text DEFAULT NULL,
  p_seat_count int DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_layout_x numeric DEFAULT NULL,
  p_layout_y numeric DEFAULT NULL,
  p_layout_w numeric DEFAULT NULL,
  p_layout_h numeric DEFAULT NULL,
  p_layout_rotation int DEFAULT NULL,
  p_layout_shape text DEFAULT NULL,
  p_layout_sort_order int DEFAULT NULL,
  p_floor_label text DEFAULT NULL
) RETURNS public.tables
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
  v_table_number text := NULLIF(btrim(COALESCE(p_table_number, '')), '');
  v_layout_shape text := NULLIF(btrim(COALESCE(p_layout_shape, '')), '');
  v_floor_label text := NULLIF(btrim(COALESCE(p_floor_label, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_STORE_REQUIRED';
  END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('available', 'reserved', 'occupied') THEN
    RAISE EXCEPTION 'TABLE_STATUS_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_existing.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'TABLE_STORE_MISMATCH';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_floor_label IS NOT NULL THEN
    IF v_floor_label IS NULL THEN
      RAISE EXCEPTION 'TABLE_FLOOR_LABEL_REQUIRED';
    END IF;
    IF v_floor_label IS DISTINCT FROM v_existing.floor_label THEN
      v_changed_fields := array_append(v_changed_fields, 'floor_label');
      v_old_values := v_old_values || jsonb_build_object('floor_label', v_existing.floor_label);
      v_new_values := v_new_values || jsonb_build_object('floor_label', v_floor_label);
    END IF;
  ELSE
    v_floor_label := v_existing.floor_label;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  IF p_layout_x IS NOT NULL AND p_layout_x IS DISTINCT FROM v_existing.layout_x THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_x');
    v_old_values := v_old_values || jsonb_build_object('layout_x', v_existing.layout_x);
    v_new_values := v_new_values || jsonb_build_object('layout_x', p_layout_x);
  END IF;

  IF p_layout_y IS NOT NULL AND p_layout_y IS DISTINCT FROM v_existing.layout_y THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_y');
    v_old_values := v_old_values || jsonb_build_object('layout_y', v_existing.layout_y);
    v_new_values := v_new_values || jsonb_build_object('layout_y', p_layout_y);
  END IF;

  IF p_layout_w IS NOT NULL AND p_layout_w IS DISTINCT FROM v_existing.layout_w THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_w');
    v_old_values := v_old_values || jsonb_build_object('layout_w', v_existing.layout_w);
    v_new_values := v_new_values || jsonb_build_object('layout_w', p_layout_w);
  END IF;

  IF p_layout_h IS NOT NULL AND p_layout_h IS DISTINCT FROM v_existing.layout_h THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_h');
    v_old_values := v_old_values || jsonb_build_object('layout_h', v_existing.layout_h);
    v_new_values := v_new_values || jsonb_build_object('layout_h', p_layout_h);
  END IF;

  IF p_layout_rotation IS NOT NULL AND p_layout_rotation IS DISTINCT FROM v_existing.layout_rotation THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_rotation');
    v_old_values := v_old_values || jsonb_build_object('layout_rotation', v_existing.layout_rotation);
    v_new_values := v_new_values || jsonb_build_object('layout_rotation', p_layout_rotation);
  END IF;

  IF p_layout_shape IS NOT NULL THEN
    IF v_layout_shape NOT IN ('rectangle', 'round') THEN
      RAISE EXCEPTION 'TABLE_LAYOUT_SHAPE_INVALID';
    END IF;
    IF v_layout_shape IS DISTINCT FROM v_existing.layout_shape THEN
      v_changed_fields := array_append(v_changed_fields, 'layout_shape');
      v_old_values := v_old_values || jsonb_build_object('layout_shape', v_existing.layout_shape);
      v_new_values := v_new_values || jsonb_build_object('layout_shape', v_layout_shape);
    END IF;
  ELSE
    v_layout_shape := v_existing.layout_shape;
  END IF;

  IF p_layout_sort_order IS NOT NULL AND p_layout_sort_order IS DISTINCT FROM v_existing.layout_sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_sort_order');
    v_old_values := v_old_values || jsonb_build_object('layout_sort_order', v_existing.layout_sort_order);
    v_new_values := v_new_values || jsonb_build_object('layout_sort_order', p_layout_sort_order);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      floor_label = v_floor_label,
      layout_x = COALESCE(p_layout_x, v_existing.layout_x),
      layout_y = COALESCE(p_layout_y, v_existing.layout_y),
      layout_w = COALESCE(p_layout_w, v_existing.layout_w),
      layout_h = COALESCE(p_layout_h, v_existing.layout_h),
      layout_rotation = COALESCE(p_layout_rotation, v_existing.layout_rotation),
      layout_shape = v_layout_shape,
      layout_sort_order = COALESCE(p_layout_sort_order, v_existing.layout_sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'store_id', p_store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;

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

  IF v_purpose IS NULL OR v_purpose NOT IN ('kitchen', 'floor', 'tray') THEN
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

CREATE OR REPLACE FUNCTION public.admin_delete_printer_destination(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.printer_destinations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_existing public.printer_destinations%ROWTYPE;
  v_saved public.printer_destinations%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

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
  SET is_active = false,
      updated_at = now()
  WHERE id = p_destination_id
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_printer_destination',
    'printer_destinations',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'purpose', v_saved.purpose,
      'floor_label', v_saved.floor_label,
      'soft_deleted', true,
      'updated_at_utc', now()
    )
  );

  RETURN v_saved;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_table(uuid, text, int, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_update_table(uuid, uuid, text, int, text, numeric, numeric, numeric, numeric, int, text, int, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_upsert_printer_destination(uuid, uuid, text, text, int, text, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_create_table(uuid, text, int, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_table(uuid, uuid, text, int, text, numeric, numeric, numeric, numeric, int, text, int, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination(uuid, uuid, text, text, int, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_table(uuid, text, int, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_table(uuid, uuid, text, int, text, numeric, numeric, numeric, numeric, int, text, int, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination(uuid, uuid, text, text, int, text, text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) TO service_role;

COMMIT;
