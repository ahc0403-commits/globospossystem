BEGIN;

-- Audit finding A: table mutations must carry the active store boundary.
DROP FUNCTION IF EXISTS public.admin_update_table(
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
  p_table_id UUID,
  p_store_id UUID,
  p_table_number TEXT DEFAULT NULL,
  p_seat_count INT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_layout_x NUMERIC DEFAULT NULL,
  p_layout_y NUMERIC DEFAULT NULL,
  p_layout_w NUMERIC DEFAULT NULL,
  p_layout_h NUMERIC DEFAULT NULL,
  p_layout_rotation INT DEFAULT NULL,
  p_layout_shape TEXT DEFAULT NULL,
  p_layout_sort_order INT DEFAULT NULL
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
  v_layout_shape TEXT := NULLIF(btrim(COALESCE(p_layout_shape, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_STORE_REQUIRED';
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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

DROP FUNCTION IF EXISTS public.admin_delete_table(uuid);

CREATE OR REPLACE FUNCTION public.admin_delete_table(
  p_table_id UUID,
  p_store_id UUID
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_STORE_REQUIRED';
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

  DELETE FROM public.tables
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_table',
    'tables',
    v_existing.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'table_number', v_existing.table_number,
        'seat_count', v_existing.seat_count,
        'status', v_existing.status
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- Audit finding D: move PIN/payroll cache writes behind explicit store RPCs.
CREATE OR REPLACE FUNCTION public.set_payroll_pin(
  p_store_id UUID,
  p_payroll_pin TEXT
) RETURNS public.restaurant_settings AS $$
DECLARE
  v_updated public.restaurant_settings%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_payroll_pin, '')), '') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (restaurant_id, payroll_pin, updated_at)
  VALUES (p_store_id, p_payroll_pin, now())
  ON CONFLICT (restaurant_id)
  DO UPDATE SET payroll_pin = EXCLUDED.payroll_pin,
                updated_at = now()
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'set_payroll_pin',
    'restaurant_settings',
    v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.clear_payroll_pin(
  p_store_id UUID
) RETURNS public.restaurant_settings AS $$
DECLARE
  v_updated public.restaurant_settings%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (restaurant_id, payroll_pin, updated_at)
  VALUES (p_store_id, NULL, now())
  ON CONFLICT (restaurant_id)
  DO UPDATE SET payroll_pin = NULL,
                updated_at = now()
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'clear_payroll_pin',
    'restaurant_settings',
    v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.save_payroll_cache(
  p_store_id UUID,
  p_period_start DATE,
  p_period_end DATE,
  p_payrolls JSONB
) RETURNS INTEGER AS $$
DECLARE
  v_row JSONB;
  v_inserted_count INTEGER := 0;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF p_period_start IS NULL OR p_period_end IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PERIOD_REQUIRED';
  END IF;

  IF p_payrolls IS NULL OR jsonb_typeof(p_payrolls) <> 'array' THEN
    RAISE EXCEPTION 'PAYROLL_ROWS_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_payrolls)
  LOOP
    IF NULLIF(v_row->>'user_id', '') IS NULL THEN
      RAISE EXCEPTION 'PAYROLL_USER_ID_REQUIRED';
    END IF;

    INSERT INTO public.payroll_records (
      restaurant_id,
      user_id,
      period_start,
      period_end,
      total_hours,
      total_amount,
      breakdown
    )
    VALUES (
      p_store_id,
      (v_row->>'user_id')::UUID,
      p_period_start,
      p_period_end,
      COALESCE(NULLIF(v_row->>'total_hours', '')::NUMERIC, 0),
      COALESCE(NULLIF(v_row->>'total_amount', '')::NUMERIC, 0),
      COALESCE(v_row->'breakdown', '[]'::JSONB)
    );

    v_inserted_count := v_inserted_count + 1;
  END LOOP;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'save_payroll_cache',
    'payroll_records',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'period_start', p_period_start,
      'period_end', p_period_end,
      'inserted_count', v_inserted_count,
      'updated_at_utc', now()
    )
  );

  RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.admin_update_table(UUID, UUID, TEXT, INT, TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, INT, TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_table(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_payroll_cache(UUID, DATE, DATE, JSONB) TO authenticated;

COMMIT;
