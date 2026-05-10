-- ============================================================
-- Table floor layout metadata
-- 2026-05-02
-- Adds normalized layout fields to public.tables and extends
-- admin table RPCs without changing existing order/table FKs.
-- ============================================================

ALTER TABLE public.tables
  ADD COLUMN IF NOT EXISTS layout_x NUMERIC(6,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_y NUMERIC(6,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_w NUMERIC(6,4) NOT NULL DEFAULT 0.18,
  ADD COLUMN IF NOT EXISTS layout_h NUMERIC(6,4) NOT NULL DEFAULT 0.14,
  ADD COLUMN IF NOT EXISTS layout_rotation INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_shape TEXT NOT NULL DEFAULT 'rectangle',
  ADD COLUMN IF NOT EXISTS layout_sort_order INT NOT NULL DEFAULT 0;

ALTER TABLE public.tables
  DROP CONSTRAINT IF EXISTS tables_layout_shape_check,
  DROP CONSTRAINT IF EXISTS tables_layout_bounds_check;

ALTER TABLE public.tables
  ADD CONSTRAINT tables_layout_shape_check
  CHECK (layout_shape IN ('rectangle', 'round')),
  ADD CONSTRAINT tables_layout_bounds_check
  CHECK (
    layout_x >= 0 AND layout_x <= 1 AND
    layout_y >= 0 AND layout_y <= 1 AND
    layout_w > 0 AND layout_w <= 1 AND
    layout_h > 0 AND layout_h <= 1 AND
    layout_x + layout_w <= 1 AND
    layout_y + layout_h <= 1 AND
    layout_rotation >= -180 AND layout_rotation <= 180
  );

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY restaurant_id
      ORDER BY table_number
    ) - 1 AS index_zero
  FROM public.tables
)
UPDATE public.tables AS t
SET
  layout_x = ((ranked.index_zero % 4) * 0.22)::NUMERIC(6,4),
  layout_y = (LEAST((ranked.index_zero / 4) * 0.18, 0.86))::NUMERIC(6,4),
  layout_w = 0.18,
  layout_h = 0.14,
  layout_sort_order = ranked.index_zero
FROM ranked
WHERE ranked.id = t.id
  AND t.layout_sort_order = 0
  AND t.layout_x = 0
  AND t.layout_y = 0;

CREATE INDEX IF NOT EXISTS idx_tables_restaurant_layout_sort
  ON public.tables (restaurant_id, layout_sort_order, table_number);

DROP FUNCTION IF EXISTS public.admin_create_table(uuid, text, int);

CREATE OR REPLACE FUNCTION public.admin_create_table(
  p_store_id UUID,
  p_table_number TEXT,
  p_seat_count INT
) RETURNS public.tables AS $$
DECLARE
  v_created public.tables%ROWTYPE;
  v_next_sort_order INT;
  v_next_x NUMERIC(6,4);
  v_next_y NUMERIC(6,4);
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  SELECT COALESCE(MAX(layout_sort_order), -1) + 1
  INTO v_next_sort_order
  FROM public.tables
  WHERE restaurant_id = p_store_id;

  v_next_x := ((v_next_sort_order % 4) * 0.22)::NUMERIC(6,4);
  v_next_y := (LEAST((v_next_sort_order / 4) * 0.18, 0.86))::NUMERIC(6,4);

  INSERT INTO public.tables (
    restaurant_id,
    table_number,
    seat_count,
    status,
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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

DROP FUNCTION IF EXISTS public.admin_update_table(uuid, text, int, text);

CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id UUID,
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

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

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
        'store_id', v_updated.restaurant_id,
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
