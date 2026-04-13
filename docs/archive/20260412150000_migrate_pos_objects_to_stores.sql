-- ============================================================================
-- Phase 2 Step 2 (Migrate): rewrite POS objects to store-path compatibility
-- Scope: POS-only migrate stage on staging. No production changes.
-- ============================================================================

BEGIN;

-- Section A0 - store-path helper views for current restaurant-era base tables

CREATE OR REPLACE VIEW public.store_settings AS
SELECT
  id,
  restaurant_id AS store_id,
  payroll_pin,
  settings_json,
  updated_at
FROM public.restaurant_settings;

CREATE OR REPLACE VIEW public.users_store_bridge AS
SELECT
  id,
  auth_id,
  restaurant_id AS store_id,
  role,
  full_name,
  is_active,
  created_at,
  extra_permissions
FROM public.users;

CREATE OR REPLACE VIEW public.tables_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  table_number,
  seat_count,
  status,
  created_at,
  updated_at
FROM public.tables;

CREATE OR REPLACE VIEW public.menu_categories_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  name,
  sort_order,
  is_active,
  created_at
FROM public.menu_categories;

CREATE OR REPLACE VIEW public.menu_items_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  category_id,
  name,
  description,
  price,
  is_available,
  is_visible_public,
  sort_order,
  created_at,
  updated_at
FROM public.menu_items;

CREATE OR REPLACE VIEW public.orders_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  table_id,
  sales_channel,
  status,
  guest_count,
  created_by,
  notes,
  created_at,
  updated_at
FROM public.orders;

CREATE OR REPLACE VIEW public.order_items_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  order_id,
  menu_item_id,
  item_type,
  label,
  unit_price,
  quantity,
  status,
  notes,
  created_at
FROM public.order_items;

CREATE OR REPLACE VIEW public.payments_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  order_id,
  amount,
  method,
  is_revenue,
  processed_by,
  notes,
  created_at
FROM public.payments;

CREATE OR REPLACE VIEW public.attendance_logs_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  user_id,
  type,
  logged_at,
  created_at,
  photo_url,
  photo_thumbnail_url
FROM public.attendance_logs;

CREATE OR REPLACE VIEW public.inventory_items_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  name,
  quantity,
  unit,
  created_at,
  updated_at,
  current_stock,
  reorder_point,
  cost_per_unit,
  supplier_name
FROM public.inventory_items;

CREATE OR REPLACE VIEW public.external_sales_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  source_system,
  external_order_id,
  sales_channel,
  gross_amount,
  discount_amount,
  delivery_fee,
  net_amount,
  currency,
  order_status,
  is_revenue,
  completed_at,
  payload,
  created_at,
  updated_at,
  settlement_id
FROM public.external_sales;

CREATE OR REPLACE VIEW public.menu_recipes_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  menu_item_id,
  ingredient_id,
  quantity_g,
  created_at,
  updated_at
FROM public.menu_recipes;

CREATE OR REPLACE VIEW public.inventory_transactions_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  ingredient_id,
  transaction_type,
  quantity_g,
  reference_type,
  reference_id,
  note,
  created_by,
  created_at
FROM public.inventory_transactions;

CREATE OR REPLACE VIEW public.inventory_physical_counts_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  ingredient_id,
  count_date,
  actual_quantity_g,
  theoretical_quantity_g,
  variance_g,
  counted_by,
  created_at,
  updated_at
FROM public.inventory_physical_counts;

CREATE OR REPLACE VIEW public.qc_templates_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  category,
  criteria_text,
  criteria_photo_url,
  sort_order,
  is_active,
  created_at,
  is_global,
  updated_at
FROM public.qc_templates;

CREATE OR REPLACE VIEW public.qc_checks_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  template_id,
  check_date,
  checked_by,
  result,
  evidence_photo_url,
  note,
  created_at
FROM public.qc_checks;

CREATE OR REPLACE VIEW public.staff_wage_configs_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  user_id,
  wage_type,
  hourly_rate,
  shift_rates,
  effective_from,
  is_active,
  created_at
FROM public.staff_wage_configs;

CREATE OR REPLACE VIEW public.payroll_records_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  user_id,
  period_start,
  period_end,
  total_hours,
  total_amount,
  breakdown,
  status,
  confirmed_by,
  created_at,
  updated_at
FROM public.payroll_records;

CREATE OR REPLACE VIEW public.delivery_settlements_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  source_system,
  period_start,
  period_end,
  period_label,
  gross_total,
  total_deductions,
  net_settlement,
  status,
  received_at,
  notes,
  created_at,
  updated_at
FROM public.delivery_settlements;

CREATE OR REPLACE VIEW public.qc_followups_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  source_check_id,
  status,
  assigned_to_name,
  resolution_notes,
  created_by,
  created_at,
  updated_at,
  resolved_at
FROM public.qc_followups;

CREATE OR REPLACE VIEW public.office_payroll_reviews_store_bridge AS
SELECT
  id,
  source_payroll_id,
  restaurant_id AS store_id,
  brand_id,
  period_start,
  period_end,
  status,
  reviewed_by,
  confirmed_by,
  review_notes,
  created_at,
  updated_at
FROM public.office_payroll_reviews;

CREATE OR REPLACE VIEW public.daily_closings_store_bridge AS
SELECT
  id,
  restaurant_id AS store_id,
  closing_date,
  closed_by,
  orders_total,
  orders_completed,
  orders_cancelled,
  items_cancelled,
  payments_count,
  payments_total,
  payments_cash,
  payments_card,
  payments_pay,
  service_count,
  service_total,
  notes,
  created_at,
  low_stock_count
FROM public.daily_closings;

-- Section A - Functions / RPC bodies

CREATE OR REPLACE FUNCTION public.add_items_to_order(p_order_id uuid, p_restaurant_id uuid, p_items jsonb)
 RETURNS SETOF order_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_order public.orders_store_bridge%ROWTYPE;
  v_inserted_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders_store_bridge
  WHERE id = p_order_id
    AND store_id = $2
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
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items_store_bridge m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = $2
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO public.order_items_store_bridge (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    store_id,
    item_type
  )
  SELECT
    p_order_id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    $2,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items_store_bridge m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.store_id = $2
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE public.orders_store_bridge
  SET updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', $2,
      'added_item_count', v_inserted_count
    )
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_create_menu_category(p_restaurant_id uuid, p_name text, p_sort_order integer DEFAULT 0)
 RETURNS menu_categories
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_created public.menu_categories_store_bridge%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant($1);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
  END IF;

  INSERT INTO public.menu_categories_store_bridge (
    store_id,
    name,
    sort_order,
    is_active,
    created_at
  )
  VALUES (
    $1,
    btrim(p_name),
    COALESCE(p_sort_order, 0),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_category',
    'menu_categories',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'sort_order', v_created.sort_order,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_create_menu_item(p_restaurant_id uuid, p_category_id uuid, p_name text, p_price numeric, p_sort_order integer DEFAULT 0, p_description text DEFAULT NULL::text, p_is_available boolean DEFAULT true, p_is_visible_public boolean DEFAULT false)
 RETURNS menu_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_created public.menu_items_store_bridge%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant($1);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories_store_bridge
    WHERE id = p_category_id
      AND store_id = $1
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items_store_bridge (
    store_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  )
  VALUES (
    $1,
    p_category_id,
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_price,
    COALESCE(p_is_available, TRUE),
    COALESCE(p_is_visible_public, FALSE),
    COALESCE(p_sort_order, 0),
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_item',
    'menu_items',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'category_id', v_created.category_id,
        'name', v_created.name,
        'description', v_created.description,
        'price', v_created.price,
        'is_available', v_created.is_available,
        'is_visible_public', v_created.is_visible_public,
        'sort_order', v_created.sort_order
      )
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_create_restaurant(p_name text, p_slug text, p_operation_mode text, p_address text DEFAULT NULL::text, p_per_person_charge numeric DEFAULT NULL::numeric, p_brand_id uuid DEFAULT NULL::uuid, p_store_type text DEFAULT 'direct'::text)
 RETURNS restaurants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_created public.stores%ROWTYPE;
BEGIN
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_operation_mode, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_CREATE_FORBIDDEN';
  END IF;

  INSERT INTO public.stores (
    name,
    address,
    slug,
    operation_mode,
    per_person_charge,
    brand_id,
    store_type,
    is_active,
    created_at
  )
  VALUES (
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''),
    lower(p_operation_mode),
    p_per_person_charge,
    p_brand_id,
    COALESCE(p_store_type, 'direct'),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_restaurant',
    'stores',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'address', v_created.address,
        'slug', v_created.slug,
        'operation_mode', v_created.operation_mode,
        'per_person_charge', v_created.per_person_charge,
        'brand_id', v_created.brand_id,
        'store_type', v_created.store_type,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_create_table(p_restaurant_id uuid, p_table_number text, p_seat_count integer)
 RETURNS tables
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_created public.tables_store_bridge%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant($1);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  INSERT INTO public.tables_store_bridge (
    store_id,
    table_number,
    seat_count,
    status,
    created_at,
    updated_at
  )
  VALUES (
    $1,
    btrim(p_table_number),
    p_seat_count,
    'available',
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
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'table_number', v_created.table_number,
        'seat_count', v_created.seat_count,
        'status', v_created.status
      )
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_deactivate_restaurant(p_restaurant_id uuid)
 RETURNS restaurants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  UPDATE public.stores
  SET is_active = FALSE
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_deactivate_restaurant',
    'stores',
    v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.id,
      'changed_fields', jsonb_build_array('is_active'),
      'old_values', jsonb_build_object('is_active', v_existing.is_active),
      'new_values', jsonb_build_object('is_active', v_updated.is_active),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_delete_menu_category(p_category_id uuid)
 RETURNS menu_categories
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.menu_categories_store_bridge%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories_store_bridge
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

  DELETE FROM public.menu_categories_store_bridge
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'sort_order', v_existing.sort_order,
        'is_active', v_existing.is_active
      )
    )
  );

  RETURN v_existing;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_delete_menu_item(p_item_id uuid)
 RETURNS menu_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.menu_items_store_bridge%ROWTYPE;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items_store_bridge
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

  DELETE FROM public.menu_items_store_bridge
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_item',
    'menu_items',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'category_id', v_existing.category_id,
        'name', v_existing.name,
        'description', v_existing.description,
        'price', v_existing.price,
        'is_available', v_existing.is_available,
        'is_visible_public', v_existing.is_visible_public,
        'sort_order', v_existing.sort_order
      )
    )
  );

  RETURN v_existing;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_delete_table(p_table_id uuid)
 RETURNS tables
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.tables_store_bridge%ROWTYPE;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables_store_bridge
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

  DELETE FROM public.tables_store_bridge
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_table',
    'tables',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
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
$function$

CREATE OR REPLACE FUNCTION public.admin_update_menu_category(p_category_id uuid, p_name text DEFAULT NULL::text, p_sort_order integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS menu_categories
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.menu_categories_store_bridge%ROWTYPE;
  v_updated public.menu_categories_store_bridge%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories_store_bridge
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_existing.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_existing.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  UPDATE public.menu_categories_store_bridge
  SET name = v_name,
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      is_active = COALESCE(p_is_active, v_existing.is_active)
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_category',
      'menu_categories',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_update_menu_item(p_item_id uuid, p_category_id uuid DEFAULT NULL::uuid, p_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_price numeric DEFAULT NULL::numeric, p_is_available boolean DEFAULT NULL::boolean, p_is_visible_public boolean DEFAULT NULL::boolean, p_sort_order integer DEFAULT NULL::integer)
 RETURNS menu_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.menu_items_store_bridge%ROWTYPE;
  v_updated public.menu_items_store_bridge%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_description TEXT := NULLIF(btrim(COALESCE(p_description, '')), '');
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items_store_bridge
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories_store_bridge
    WHERE id = p_category_id
      AND store_id = v_existing.store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_category_id IS NOT NULL AND p_category_id IS DISTINCT FROM v_existing.category_id THEN
    v_changed_fields := array_append(v_changed_fields, 'category_id');
    v_old_values := v_old_values || jsonb_build_object('category_id', v_existing.category_id);
    v_new_values := v_new_values || jsonb_build_object('category_id', p_category_id);
  END IF;

  IF p_description IS NOT NULL AND v_description IS DISTINCT FROM v_existing.description THEN
    v_changed_fields := array_append(v_changed_fields, 'description');
    v_old_values := v_old_values || jsonb_build_object('description', v_existing.description);
    v_new_values := v_new_values || jsonb_build_object('description', v_description);
  END IF;

  IF p_price IS NOT NULL AND p_price IS DISTINCT FROM v_existing.price THEN
    v_changed_fields := array_append(v_changed_fields, 'price');
    v_old_values := v_old_values || jsonb_build_object('price', v_existing.price);
    v_new_values := v_new_values || jsonb_build_object('price', p_price);
  END IF;

  IF p_is_available IS NOT NULL AND p_is_available IS DISTINCT FROM v_existing.is_available THEN
    v_changed_fields := array_append(v_changed_fields, 'is_available');
    v_old_values := v_old_values || jsonb_build_object('is_available', v_existing.is_available);
    v_new_values := v_new_values || jsonb_build_object('is_available', p_is_available);
  END IF;

  IF p_is_visible_public IS NOT NULL AND p_is_visible_public IS DISTINCT FROM v_existing.is_visible_public THEN
    v_changed_fields := array_append(v_changed_fields, 'is_visible_public');
    v_old_values := v_old_values || jsonb_build_object('is_visible_public', v_existing.is_visible_public);
    v_new_values := v_new_values || jsonb_build_object('is_visible_public', p_is_visible_public);
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  UPDATE public.menu_items_store_bridge
  SET category_id = COALESCE(p_category_id, v_existing.category_id),
      name = v_name,
      description = CASE
        WHEN p_description IS NULL THEN v_existing.description
        ELSE v_description
      END,
      price = COALESCE(p_price, v_existing.price),
      is_available = COALESCE(p_is_available, v_existing.is_available),
      is_visible_public = COALESCE(p_is_visible_public, v_existing.is_visible_public),
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_item',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_update_restaurant(p_restaurant_id uuid, p_name text, p_slug text, p_operation_mode text, p_address text DEFAULT NULL::text, p_per_person_charge numeric DEFAULT NULL::numeric, p_brand_id uuid DEFAULT NULL::uuid, p_store_type text DEFAULT 'direct'::text)
 RETURNS restaurants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_slug TEXT := NULLIF(btrim(COALESCE(p_slug, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  v_actor := public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_slug IS DISTINCT FROM v_existing.slug THEN
    v_changed_fields := array_append(v_changed_fields, 'slug');
    v_old_values := v_old_values || jsonb_build_object('slug', v_existing.slug);
    v_new_values := v_new_values || jsonb_build_object('slug', v_slug);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF p_brand_id IS DISTINCT FROM v_existing.brand_id THEN
    v_changed_fields := array_append(v_changed_fields, 'brand_id');
    v_old_values := v_old_values || jsonb_build_object('brand_id', v_existing.brand_id);
    v_new_values := v_new_values || jsonb_build_object('brand_id', p_brand_id);
  END IF;

  IF COALESCE(p_store_type, 'direct') IS DISTINCT FROM v_existing.store_type THEN
    v_changed_fields := array_append(v_changed_fields, 'store_type');
    v_old_values := v_old_values || jsonb_build_object('store_type', v_existing.store_type);
    v_new_values := v_new_values || jsonb_build_object('store_type', COALESCE(p_store_type, 'direct'));
  END IF;

  UPDATE public.stores
  SET name = v_name,
      address = v_address,
      slug = v_slug,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      brand_id = p_brand_id,
      store_type = COALESCE(p_store_type, 'direct')
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant',
      'stores',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_update_restaurant_settings(p_restaurant_id uuid, p_name text, p_operation_mode text, p_address text DEFAULT NULL::text, p_per_person_charge numeric DEFAULT NULL::numeric)
 RETURNS restaurants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  UPDATE public.stores
  SET name = v_name,
      address = v_address,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_store_settings',
      'stores',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_update_staff_account(p_user_id uuid, p_restaurant_id uuid, p_full_name text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean, p_extra_permissions text[] DEFAULT NULL::text[])
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_target public.users_store_bridge%ROWTYPE;
  v_updated public.users_store_bridge%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL OR $2 IS NULL THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_target
  FROM public.users_store_bridge
  WHERE id = p_user_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND';
  END IF;

  IF v_actor.role = 'admin'
     AND v_target.role IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_full_name IS NOT NULL THEN
    IF v_full_name IS NULL THEN
      RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
    END IF;
    IF v_full_name IS DISTINCT FROM v_target.full_name THEN
      v_changed_fields := array_append(v_changed_fields, 'full_name');
      v_old_values := v_old_values || jsonb_build_object('full_name', v_target.full_name);
      v_new_values := v_new_values || jsonb_build_object('full_name', v_full_name);
    END IF;
  ELSE
    v_full_name := v_target.full_name;
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_target.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_target.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  IF p_extra_permissions IS NOT NULL
     AND COALESCE(p_extra_permissions, ARRAY[]::TEXT[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::TEXT[]));
  END IF;

  UPDATE public.users_store_bridge
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE
        WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions
        ELSE COALESCE(p_extra_permissions, ARRAY[]::TEXT[])
      END
  WHERE id = v_target.id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_staff_account',
      'users',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.admin_update_table(p_table_id uuid, p_table_number text DEFAULT NULL::text, p_seat_count integer DEFAULT NULL::integer, p_status text DEFAULT NULL::text)
 RETURNS tables
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_existing public.tables_store_bridge%ROWTYPE;
  v_updated public.tables_store_bridge%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables_store_bridge
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.store_id);

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

  UPDATE public.tables_store_bridge
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
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
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.apply_inventory_physical_count_line(p_restaurant_id uuid, p_count_date date, p_ingredient_id uuid, p_actual_quantity_g numeric, p_note text DEFAULT NULL::text)
 RETURNS TABLE(ingredient_id uuid, count_date date, theoretical_quantity_g numeric, actual_quantity_g numeric, variance_quantity_g numeric, inventory_transaction_id uuid, last_updated timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_ingredient public.inventory_items_store_bridge%ROWTYPE;
  v_existing_count public.inventory_physical_counts_store_bridge%ROWTYPE;
  v_count_row public.inventory_physical_counts_store_bridge%ROWTYPE;
  v_transaction public.inventory_transactions_store_bridge%ROWTYPE;
  v_old_stock DECIMAL(12,3);
  v_variance DECIMAL(12,3);
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED';
  END IF;

  IF p_actual_quantity_g IS NULL OR p_actual_quantity_g < 0 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items_store_bridge ii
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  v_old_stock := v_ingredient.current_stock;
  v_variance := p_actual_quantity_g - v_old_stock;

  SELECT ipc.*
  INTO v_existing_count
  FROM public.inventory_physical_counts_store_bridge ipc
  WHERE ipc.store_id = $1
    AND ipc.ingredient_id = p_ingredient_id
    AND ipc.count_date = p_count_date
  FOR UPDATE;

  INSERT INTO public.inventory_physical_counts_store_bridge (
    store_id,
    ingredient_id,
    count_date,
    actual_quantity_g,
    theoretical_quantity_g,
    variance_g,
    counted_by,
    updated_at
  )
  VALUES (
    $1,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_old_stock,
    v_variance,
    auth.uid(),
    now()
  )
  ON CONFLICT ON CONSTRAINT inventory_physical_counts_ingredient_id_count_date_key
  DO UPDATE SET
    actual_quantity_g = EXCLUDED.actual_quantity_g,
    theoretical_quantity_g = EXCLUDED.theoretical_quantity_g,
    variance_g = EXCLUDED.variance_g,
    counted_by = EXCLUDED.counted_by,
    updated_at = now()
  RETURNING * INTO v_count_row;

  UPDATE public.inventory_items_store_bridge ii
  SET current_stock = p_actual_quantity_g,
      updated_at = now()
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = $1;

  INSERT INTO public.inventory_transactions_store_bridge (
    store_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  VALUES (
    $1,
    p_ingredient_id,
    'adjust',
    v_variance,
    'physical_count',
    v_count_row.id,
    COALESCE(
      v_note,
      format('실재고 실사 (%s)', to_char(p_count_date, 'YYYY-MM-DD'))
    ),
    auth.uid()
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_physical_count_applied',
    'inventory_physical_counts',
    v_count_row.id,
    jsonb_build_object(
      'store_id', $1,
      'ingredient_id', p_ingredient_id,
      'count_date', p_count_date,
      'old_stock', v_old_stock,
      'new_stock', p_actual_quantity_g,
      'variance_quantity_g', v_variance,
      'note', v_note,
      'previous_count', CASE
        WHEN v_existing_count.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'actual_quantity_g', v_existing_count.actual_quantity_g,
          'theoretical_quantity_g', v_existing_count.theoretical_quantity_g,
          'variance_g', v_existing_count.variance_g
        )
      END
    )
  );

  RETURN QUERY
  SELECT
    p_ingredient_id AS ingredient_id,
    p_count_date AS count_date,
    v_old_stock AS theoretical_quantity_g,
    p_actual_quantity_g AS actual_quantity_g,
    v_variance AS variance_quantity_g,
    v_transaction.id AS inventory_transaction_id,
    v_count_row.updated_at AS last_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid, p_restaurant_id uuid)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_order public.orders_store_bridge%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders_store_bridge
  WHERE id = p_order_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE public.orders_store_bridge
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables_store_bridge
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', $2,
      'from_status', 'pending_or_confirmed',
      'to_status', 'cancelled'
    )
  );

  RETURN v_order;
END;
$function$

CREATE OR REPLACE FUNCTION public.cancel_order_item(p_item_id uuid, p_restaurant_id uuid)
 RETURNS order_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_item public.order_items_store_bridge%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Lock item
  SELECT *
  INTO v_item
  FROM public.order_items_store_bridge
  WHERE id = p_item_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM public.orders_store_bridge
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending/preparing items can be cancelled
  IF v_item.status NOT IN ('pending', 'preparing') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE public.order_items_store_bridge
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  -- Update order timestamp
  UPDATE public.orders_store_bridge
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', $2,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$function$

CREATE OR REPLACE FUNCTION public.complete_onboarding_account_setup(p_restaurant_id uuid, p_full_name text, p_role text)
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_updated public.users_store_bridge%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'ONBOARDING_RESTAURANT_REQUIRED';
  END IF;

  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
  END IF;

  IF p_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ONBOARDING_ROLE_INVALID';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'ONBOARDING_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  UPDATE public.users_store_bridge
  SET store_id = $1,
      full_name = v_full_name,
      role = p_role
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'complete_onboarding_account_setup',
    'users',
    v_updated.id,
    jsonb_build_object(
      'store_id', $1,
      'new_role', p_role
    )
  );

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.confirm_delivery_settlement_received(p_settlement_id uuid, p_restaurant_id uuid)
 RETURNS delivery_settlements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor_id UUID := auth.uid();
  v_actor public.users_store_bridge%ROWTYPE;
  v_settlement public.delivery_settlements_store_bridge%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = v_actor_id
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_settlement
  FROM public.delivery_settlements_store_bridge
  WHERE id = p_settlement_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  IF v_settlement.status <> 'calculated' THEN
    RAISE EXCEPTION 'INVALID_SETTLEMENT_STATUS';
  END IF;

  UPDATE public.delivery_settlements_store_bridge
  SET status = 'received',
      received_at = now(),
      updated_at = now()
  WHERE id = p_settlement_id
  RETURNING * INTO v_settlement;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'confirm_delivery_settlement_received',
    'delivery_settlements',
    p_settlement_id,
    jsonb_build_object(
      'store_id', $2,
      'from_status', 'calculated',
      'to_status', 'received'
    )
  );

  RETURN v_settlement;
END;
$function$

CREATE OR REPLACE FUNCTION public.create_buffet_order(p_restaurant_id uuid, p_table_id uuid, p_guest_count integer, p_extra_items jsonb DEFAULT '[]'::jsonb)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_table public.tables_store_bridge%ROWTYPE;
  v_operation_mode TEXT;
  v_per_person_charge DECIMAL(12,2);
  v_order public.orders_store_bridge%ROWTYPE;
  v_extra_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_table
  FROM public.tables_store_bridge
  WHERE id = p_table_id
    AND store_id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM public.stores
  WHERE id = $1;

  IF v_operation_mode NOT IN ('buffet', 'hybrid') THEN
    RAISE EXCEPTION 'OPERATION_MODE_MISMATCH';
  END IF;

  IF p_guest_count IS NULL OR p_guest_count < 1 THEN
    RAISE EXCEPTION 'BUFFET_GUEST_COUNT_REQUIRED';
  END IF;

  IF jsonb_typeof(p_extra_items) <> 'array' THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    LEFT JOIN public.menu_items_store_bridge m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = $1
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders_store_bridge (
    store_id,
    table_id,
    status,
    created_by,
    guest_count
  )
  VALUES ($1, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  INSERT INTO public.order_items_store_bridge (
    order_id,
    store_id,
    item_type,
    label,
    unit_price,
    quantity,
    status
  )
  VALUES (
    v_order.id,
    $1,
    'buffet_base',
    '1인 고정 요금',
    v_per_person_charge,
    p_guest_count,
    'served'
  );

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO public.order_items_store_bridge (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      store_id,
      item_type
    )
    SELECT
      v_order.id,
      m.id,
      (item->>'quantity')::INT,
      m.price,
      m.name,
      $1,
      'a_la_carte'
    FROM jsonb_array_elements(p_extra_items) item
    JOIN public.menu_items_store_bridge m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = $1
     AND m.is_available = TRUE;

    GET DIAGNOSTICS v_extra_item_count = ROW_COUNT;
  END IF;

  UPDATE public.tables_store_bridge
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_buffet_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', $1,
      'table_id', p_table_id,
      'guest_count', p_guest_count,
      'extra_item_count', v_extra_item_count,
      'operation_mode', v_operation_mode
    )
  );

  RETURN v_order;
END;
$function$

CREATE OR REPLACE FUNCTION public.create_daily_closing(p_restaurant_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_closing_date DATE;
  v_existing_id UUID;
  v_orders_total INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_low_stock_count INT;
  v_day_start TIMESTAMPTZ;
  v_new_id UUID;
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  -- Vietnam timezone for closing date
  v_closing_date := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE;
  v_day_start := v_closing_date::TIMESTAMPTZ;

  -- Check duplicate
  SELECT id INTO v_existing_id
  FROM public.daily_closings_store_bridge
  WHERE store_id = $1
    AND closing_date = v_closing_date;

  IF FOUND THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  -- Compute order metrics
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders_store_bridge
  WHERE store_id = $1
    AND created_at >= v_day_start;

  -- Cancelled items
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items_store_bridge oi
  JOIN public.orders_store_bridge o ON o.id = oi.order_id
  WHERE o.store_id = $1
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start;

  -- Revenue payments
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments_store_bridge
  WHERE store_id = $1
    AND is_revenue = TRUE
    AND created_at >= v_day_start;

  -- Service payments
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments_store_bridge
  WHERE store_id = $1
    AND is_revenue = FALSE
    AND created_at >= v_day_start;

  -- Low-stock count (snapshot at closing time)
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items_store_bridge
  WHERE store_id = $1
    AND is_active = TRUE
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  -- Insert closing record
  INSERT INTO public.daily_closings_store_bridge (
    store_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, low_stock_count, notes
  ) VALUES (
    $1, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, v_low_stock_count, p_notes
  ) RETURNING id INTO v_new_id;

  -- Audit log
  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_daily_closing',
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'store_id', $1,
      'closing_date', v_closing_date,
      'orders_total', v_orders_total,
      'payments_total', v_payments_total,
      'low_stock_count', v_low_stock_count
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'orders_total', v_orders_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'low_stock_count', v_low_stock_count
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.create_inventory_item(p_restaurant_id uuid, p_name text, p_unit text, p_current_stock numeric DEFAULT NULL::numeric, p_reorder_point numeric DEFAULT NULL::numeric, p_cost_per_unit numeric DEFAULT NULL::numeric, p_supplier_name text DEFAULT NULL::text)
 RETURNS inventory_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_created public.inventory_items_store_bridge%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_unit TEXT := btrim(COALESCE(p_unit, ''));
  v_current_stock DECIMAL(12,3) := COALESCE(p_current_stock, 0);
  v_reorder_point DECIMAL(12,3) := p_reorder_point;
  v_cost_per_unit DECIMAL(12,2) := p_cost_per_unit;
  v_supplier_name TEXT := NULLIF(btrim(COALESCE(p_supplier_name, '')), '');
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
  END IF;

  IF v_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
  END IF;

  IF v_reorder_point IS NOT NULL AND v_reorder_point < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
  END IF;

  IF v_cost_per_unit IS NOT NULL AND v_cost_per_unit < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items_store_bridge ii
    WHERE ii.store_id = $1
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  INSERT INTO public.inventory_items_store_bridge (
    store_id,
    name,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    updated_at
  )
  VALUES (
    $1,
    v_name,
    v_unit,
    v_current_stock,
    v_reorder_point,
    v_cost_per_unit,
    v_supplier_name,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_created',
    'inventory_items',
    v_created.id,
    jsonb_build_object(
      'store_id', $1,
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'unit', v_created.unit,
        'current_stock', v_created.current_stock,
        'reorder_point', v_created.reorder_point,
        'cost_per_unit', v_created.cost_per_unit,
        'supplier_name', v_created.supplier_name
      )
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.create_order(p_restaurant_id uuid, p_table_id uuid, p_items jsonb)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_table public.tables_store_bridge%ROWTYPE;
  v_order public.orders_store_bridge%ROWTYPE;
  v_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM public.tables_store_bridge
  WHERE id = p_table_id
    AND store_id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items_store_bridge m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = $1
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders_store_bridge (store_id, table_id, status, created_by)
  VALUES ($1, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO public.order_items_store_bridge (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    store_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    $1,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items_store_bridge m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.store_id = $1
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE public.tables_store_bridge
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', $1,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$function$

CREATE OR REPLACE FUNCTION public.create_qc_followup(p_restaurant_id uuid, p_source_check_id uuid, p_assigned_to_name text DEFAULT NULL::text)
 RETURNS qc_followups
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor      public.users_store_bridge%ROWTYPE;
  v_check      public.qc_checks_store_bridge%ROWTYPE;
  v_created    public.qc_followups_store_bridge%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  SELECT * INTO v_check
  FROM public.qc_checks_store_bridge
  WHERE id = p_source_check_id
    AND store_id = $1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_CHECK_NOT_FOUND';
  END IF;

  IF v_check.result <> 'fail' THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FAILED_CHECK';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.qc_followups_store_bridge
    WHERE source_check_id = p_source_check_id
  ) THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.qc_followups_store_bridge (
    store_id, source_check_id, status,
    assigned_to_name, created_by
  ) VALUES (
    $1, p_source_check_id, 'open',
    NULLIF(btrim(COALESCE(p_assigned_to_name, '')), ''),
    auth.uid()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_created',
    'qc_followups',
    v_created.id,
    jsonb_build_object(
      'store_id', $1,
      'source_check_id', p_source_check_id,
      'assigned_to_name', v_created.assigned_to_name
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.create_qc_template(p_category text, p_criteria_text text, p_restaurant_id uuid DEFAULT NULL::uuid, p_criteria_photo_url text DEFAULT NULL::text, p_sort_order integer DEFAULT 0, p_is_global boolean DEFAULT false)
 RETURNS qc_templates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_created public.qc_templates_store_bridge%ROWTYPE;
  v_category TEXT := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_criteria TEXT := NULLIF(btrim(COALESCE(p_criteria_text, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_criteria_photo_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF v_category IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
  END IF;

  IF v_criteria IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
  END IF;

  IF p_sort_order IS NULL OR p_sort_order < 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
  END IF;

  IF p_is_global THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  ELSE
    IF $3 IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.store_id <> $3 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  END IF;

  INSERT INTO public.qc_templates_store_bridge (
    store_id,
    category,
    criteria_text,
    criteria_photo_url,
    sort_order,
    is_global,
    updated_at
  )
  VALUES (
    CASE WHEN p_is_global THEN NULL ELSE $3 END,
    v_category,
    v_criteria,
    v_photo,
    p_sort_order,
    p_is_global,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_created',
    'qc_templates',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'is_global', v_created.is_global,
      'category', v_created.category,
      'criteria_text', v_created.criteria_text,
      'criteria_photo_url', v_created.criteria_photo_url,
      'sort_order', v_created.sort_order
    )
  );

  RETURN v_created;
END;
$function$

CREATE OR REPLACE FUNCTION public.deactivate_qc_template(p_template_id uuid)
 RETURNS qc_templates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_existing public.qc_templates_store_bridge%ROWTYPE;
  v_updated public.qc_templates_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates_store_bridge qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.store_id <> v_actor.store_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  UPDATE public.qc_templates_store_bridge
  SET is_active = FALSE,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_deactivated',
    'qc_templates',
    v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.store_id,
      'is_global', v_updated.is_global
    )
  );

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.edit_order_item_quantity(p_item_id uuid, p_restaurant_id uuid, p_new_quantity integer)
 RETURNS order_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_item public.order_items_store_bridge%ROWTYPE;
  v_order_status TEXT;
  v_old_quantity INT;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Validate quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  -- Lock item
  SELECT *
  INTO v_item
  FROM public.order_items_store_bridge
  WHERE id = p_item_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM public.orders_store_bridge
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending items can be quantity-edited
  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  -- No-op if same quantity
  IF v_old_quantity = p_new_quantity THEN
    RETURN v_item;
  END IF;

  UPDATE public.order_items_store_bridge
  SET quantity = p_new_quantity
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE public.orders_store_bridge
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'edit_order_item_quantity',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', $2,
      'order_id', v_item.order_id,
      'label', v_item.label,
      'old_quantity', v_old_quantity,
      'new_quantity', p_new_quantity
    )
  );

  RETURN v_item;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_admin_mutation_audit_trace(p_restaurant_id uuid, p_limit integer DEFAULT 10)
 RETURNS TABLE(audit_log_id uuid, created_at timestamp with time zone, action text, entity_type text, entity_id uuid, actor_id uuid, actor_name text, changed_fields jsonb, old_values jsonb, new_values jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'AUDIT_TRACE_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS audit_log_id,
    al.created_at,
    al.action,
    al.entity_type,
    al.entity_id,
    al.actor_id,
    COALESCE(u.full_name, '알 수 없음') AS actor_name,
    COALESCE(al.details -> 'changed_fields', '[]'::jsonb) AS changed_fields,
    COALESCE(al.details -> 'old_values', '{}'::jsonb) AS old_values,
    COALESCE(al.details -> 'new_values', '{}'::jsonb) AS new_values
  FROM public.audit_logs al
  LEFT JOIN public.users_store_bridge u
    ON u.auth_id = al.actor_id
  WHERE al.entity_type = ANY (
      ARRAY[
        'stores', 'tables', 'menu_categories', 'menu_items',
        'orders', 'order_items', 'payments'
      ]
    )
    AND (
      NULLIF(al.details ->> 'store_id', '')::UUID = $1
      OR (
        al.entity_type = 'stores'
        AND al.entity_id = $1
      )
    )
    AND al.action = ANY (
      ARRAY[
        -- admin mutations (existing)
        'admin_create_restaurant',
        'admin_update_restaurant',
        'admin_deactivate_restaurant',
        'admin_update_store_settings',
        'admin_create_table',
        'admin_update_table',
        'admin_delete_table',
        'admin_create_menu_category',
        'admin_update_menu_category',
        'admin_delete_menu_category',
        'admin_create_menu_item',
        'admin_update_menu_item',
        'admin_delete_menu_item',
        -- order lifecycle (new)
        'create_order',
        'create_buffet_order',
        'add_items_to_order',
        'cancel_order',
        'cancel_order_item',
        'edit_order_item_quantity',
        'transfer_order_table',
        'process_payment',
        'update_order_item_status'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_admin_today_summary(p_restaurant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_orders_pending INT;
  v_orders_confirmed INT;
  v_orders_serving INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_tables_total INT;
  v_tables_occupied INT;
  v_low_stock_count INT;
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Order counts by status
  SELECT
    COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'serving' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_pending, v_orders_confirmed, v_orders_serving,
       v_orders_completed, v_orders_cancelled
  FROM public.orders_store_bridge
  WHERE store_id = $1
    AND created_at >= v_today_start;

  -- Cancelled order items today
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items_store_bridge oi
  JOIN public.orders_store_bridge o ON o.id = oi.order_id
  WHERE o.store_id = $1
    AND oi.status = 'cancelled'
    AND o.created_at >= v_today_start;

  -- Payment counts and totals (revenue only)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) <> 'cash' THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card
  FROM public.payments_store_bridge
  WHERE store_id = $1
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Table occupancy snapshot (live, not time-filtered)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'occupied' THEN 1 ELSE 0 END), 0)
  INTO v_tables_total, v_tables_occupied
  FROM public.tables_store_bridge
  WHERE store_id = $1;

  -- Live low-stock count
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items_store_bridge
  WHERE store_id = $1
    AND is_active = TRUE
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  v_result := jsonb_build_object(
    'orders_pending', v_orders_pending,
    'orders_confirmed', v_orders_confirmed,
    'orders_serving', v_orders_serving,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_total', v_orders_pending + v_orders_confirmed + v_orders_serving + v_orders_completed + v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'tables_total', v_tables_total,
    'tables_occupied', v_tables_occupied,
    'low_stock_count', v_low_stock_count
  );

  RETURN v_result;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_attendance_log_view(p_restaurant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(attendance_log_id uuid, restaurant_id uuid, user_id uuid, user_full_name text, user_role text, attendance_type text, photo_url text, photo_thumbnail_url text, logged_at timestamp with time zone, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_INVALID';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.users_store_bridge u
    WHERE u.id = p_user_id
      AND u.store_id = $1
      AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_USER_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS attendance_log_id,
    al.store_id,
    al.user_id,
    u.full_name AS user_full_name,
    u.role AS user_role,
    al.type AS attendance_type,
    al.photo_url,
    al.photo_thumbnail_url,
    al.logged_at,
    al.created_at
  FROM public.attendance_logs_store_bridge al
  JOIN public.users_store_bridge u
    ON u.id = al.user_id
   AND u.store_id = al.store_id
  WHERE al.store_id = $1
    AND al.logged_at >= p_from
    AND al.logged_at <= p_to
    AND (p_user_id IS NULL OR al.user_id = p_user_id)
  ORDER BY al.logged_at DESC, al.created_at DESC;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_attendance_staff_directory(p_restaurant_id uuid)
 RETURNS TABLE(user_id uuid, full_name text, role text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    u.id AS user_id,
    u.full_name,
    u.role
  FROM public.users_store_bridge u
  WHERE u.store_id = $1
    AND u.is_active = TRUE
    AND u.role IN ('admin', 'waiter', 'kitchen', 'cashier')
  ORDER BY lower(u.full_name), u.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_cashier_today_summary(p_restaurant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_orders_active INT;
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role NOT IN ('admin', 'super_admin')
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Revenue payments (is_revenue = true)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments_store_bridge
  WHERE store_id = $1
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Service payments (is_revenue = false)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments_store_bridge
  WHERE store_id = $1
    AND is_revenue = FALSE
    AND created_at >= v_today_start;

  -- Order status counts for today
  SELECT
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END), 0)
  INTO v_orders_completed, v_orders_cancelled, v_orders_active
  FROM public.orders_store_bridge
  WHERE store_id = $1
    AND created_at >= v_today_start;

  v_result := jsonb_build_object(
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_active', v_orders_active
  );

  RETURN v_result;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_daily_closings(p_restaurant_id uuid, p_limit integer DEFAULT 30)
 RETURNS TABLE(closing_id uuid, closing_date date, closed_by_name text, orders_total integer, orders_completed integer, orders_cancelled integer, items_cancelled integer, payments_count integer, payments_total numeric, payments_cash numeric, payments_card numeric, payments_pay numeric, service_count integer, service_total numeric, low_stock_count integer, notes text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    dc.id AS closing_id,
    dc.closing_date,
    COALESCE(u.full_name, '알 수 없음') AS closed_by_name,
    dc.orders_total,
    dc.orders_completed,
    dc.orders_cancelled,
    dc.items_cancelled,
    dc.payments_count,
    dc.payments_total,
    dc.payments_cash,
    dc.payments_card,
    dc.payments_pay,
    dc.service_count,
    dc.service_total,
    dc.low_stock_count,
    dc.notes,
    dc.created_at
  FROM public.daily_closings_store_bridge dc
  LEFT JOIN public.users_store_bridge u ON u.auth_id = dc.closed_by
  WHERE dc.store_id = $1
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(p_restaurant_id uuid)
 RETURNS TABLE(id uuid, restaurant_id uuid, name text, unit text, current_stock numeric, reorder_point numeric, cost_per_unit numeric, supplier_name text, needs_reorder boolean, last_updated timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    ii.id,
    ii.store_id,
    ii.name,
    ii.unit,
    ii.current_stock,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
    CASE
      WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
        THEN TRUE
      ELSE FALSE
    END AS needs_reorder,
    ii.updated_at AS last_updated
  FROM public.inventory_items_store_bridge ii
  WHERE ii.store_id = $1
  ORDER BY lower(ii.name), ii.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_inventory_physical_count_sheet(p_restaurant_id uuid, p_count_date date)
 RETURNS TABLE(ingredient_id uuid, ingredient_name text, ingredient_unit text, theoretical_quantity_g numeric, actual_quantity_g numeric, variance_quantity_g numeric, count_date date, last_updated timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  RETURN QUERY
  SELECT
    ii.id AS ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    ii.current_stock AS theoretical_quantity_g,
    ipc.actual_quantity_g,
    ipc.variance_g AS variance_quantity_g,
    p_count_date AS count_date,
    COALESCE(ipc.updated_at, ipc.created_at, ii.updated_at) AS last_updated
  FROM public.inventory_items_store_bridge ii
  LEFT JOIN public.inventory_physical_counts_store_bridge ipc
    ON ipc.store_id = $1
   AND ipc.ingredient_id = ii.id
   AND ipc.count_date = p_count_date
  WHERE ii.store_id = $1
  ORDER BY lower(ii.name), ii.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_inventory_recipe_catalog(p_restaurant_id uuid, p_menu_item_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(recipe_id uuid, restaurant_id uuid, menu_item_id uuid, menu_item_name text, ingredient_id uuid, ingredient_name text, ingredient_unit text, quantity_g numeric, last_updated timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items_store_bridge mi
    WHERE mi.id = p_menu_item_id
      AND mi.store_id = $1
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    mr.id AS recipe_id,
    mr.store_id,
    mr.menu_item_id,
    mi.name AS menu_item_name,
    mr.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    mr.quantity_g,
    mr.updated_at AS last_updated
  FROM public.menu_recipes_store_bridge mr
  JOIN public.menu_items_store_bridge mi
    ON mi.id = mr.menu_item_id
   AND mi.store_id = mr.store_id
  JOIN public.inventory_items_store_bridge ii
    ON ii.id = mr.ingredient_id
   AND ii.store_id = mr.store_id
  WHERE mr.store_id = $1
    AND (p_menu_item_id IS NULL OR mr.menu_item_id = p_menu_item_id)
  ORDER BY lower(mi.name), lower(ii.name), mr.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_inventory_transaction_visibility(p_restaurant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS TABLE(id uuid, restaurant_id uuid, ingredient_id uuid, ingredient_name text, ingredient_unit text, transaction_type text, quantity_g numeric, reference_type text, reference_id uuid, note text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    it.id,
    it.store_id,
    it.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    it.transaction_type,
    it.quantity_g,
    it.reference_type,
    it.reference_id,
    it.note,
    it.created_at
  FROM public.inventory_transactions_store_bridge it
  JOIN public.inventory_items_store_bridge ii
    ON ii.id = it.ingredient_id
   AND ii.store_id = it.store_id
  WHERE it.store_id = $1
    AND it.created_at >= p_from
    AND it.created_at <= p_to
  ORDER BY it.created_at DESC, ii.name;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_qc_analytics(p_restaurant_id uuid, p_from date, p_to date)
 RETURNS TABLE(total_checks bigint, pass_count bigint, fail_count bigint, na_count bigint, pass_rate numeric, template_count bigint, coverage numeric, open_followups bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_can_check BOOLEAN;
  v_days INT;
BEGIN
  SELECT * INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'QC_ANALYTICS_RANGE_INVALID';
  END IF;

  v_days := (p_to - p_from) + 1;

  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT AS total_checks,
    COUNT(*) FILTER (WHERE qc.result = 'pass')::BIGINT AS pass_count,
    COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
    COUNT(*) FILTER (WHERE qc.result = 'na')::BIGINT AS na_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE qc.result IN ('pass','fail')) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*) FILTER (WHERE qc.result = 'pass')::NUMERIC
        / COUNT(*) FILTER (WHERE qc.result IN ('pass','fail'))::NUMERIC * 100,
        1
      )
    END AS pass_rate,
    (SELECT COUNT(*) FROM public.qc_templates_store_bridge qt
     WHERE qt.is_active = TRUE
       AND (qt.is_global = TRUE OR qt.store_id = $1)
    )::BIGINT AS template_count,
    CASE
      WHEN (SELECT COUNT(*) FROM public.qc_templates_store_bridge qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.store_id = $1)) = 0
      THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*)::NUMERIC
        / ((SELECT COUNT(*) FROM public.qc_templates_store_bridge qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.store_id = $1))
           * v_days)::NUMERIC * 100,
        1
      )
    END AS coverage,
    (SELECT COUNT(*) FROM public.qc_followups_store_bridge f
     WHERE f.store_id = $1
       AND f.status IN ('open', 'in_progress')
    )::BIGINT AS open_followups
  FROM public.qc_checks_store_bridge qc
  WHERE qc.store_id = $1
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_qc_checks(p_restaurant_id uuid, p_from date, p_to date)
 RETURNS TABLE(check_id uuid, restaurant_id uuid, template_id uuid, check_date date, checked_by uuid, result text, evidence_photo_url text, note text, created_at timestamp with time zone, template_category text, template_criteria_text text, template_criteria_photo_url text, template_is_global boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_can_check BOOLEAN;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    qc.id AS check_id,
    qc.store_id,
    qc.template_id,
    qc.check_date,
    qc.checked_by,
    qc.result,
    qc.evidence_photo_url,
    qc.note,
    qc.created_at,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria_text,
    qt.criteria_photo_url AS template_criteria_photo_url,
    qt.is_global AS template_is_global
  FROM public.qc_checks_store_bridge qc
  JOIN public.qc_templates_store_bridge qt
    ON qt.id = qc.template_id
  WHERE qc.store_id = $1
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to
  ORDER BY qc.check_date DESC, lower(qt.category), qt.sort_order, qc.created_at DESC;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_qc_followups(p_restaurant_id uuid, p_status_filter text DEFAULT NULL::text)
 RETURNS TABLE(followup_id uuid, restaurant_id uuid, source_check_id uuid, status text, assigned_to_name text, resolution_notes text, created_at timestamp with time zone, updated_at timestamp with time zone, resolved_at timestamp with time zone, check_date date, check_result text, check_note text, template_category text, template_criteria text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    f.id AS followup_id,
    f.store_id,
    f.source_check_id,
    f.status,
    f.assigned_to_name,
    f.resolution_notes,
    f.created_at,
    f.updated_at,
    f.resolved_at,
    qc.check_date,
    qc.result AS check_result,
    qc.note AS check_note,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria
  FROM public.qc_followups_store_bridge f
  JOIN public.qc_checks_store_bridge qc ON qc.id = f.source_check_id
  JOIN public.qc_templates_store_bridge qt ON qt.id = qc.template_id
  WHERE f.store_id = $1
    AND (p_status_filter IS NULL OR f.status = p_status_filter)
  ORDER BY
    CASE f.status
      WHEN 'open' THEN 0
      WHEN 'in_progress' THEN 1
      WHEN 'resolved' THEN 2
    END,
    f.created_at DESC;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_qc_superadmin_summary(p_week_start date)
 RETURNS TABLE(restaurant_id uuid, restaurant_name text, coverage numeric, fail_count bigint, latest_check_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_week_end DATE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_SUMMARY_FORBIDDEN';
  END IF;

  IF p_week_start IS NULL THEN
    RAISE EXCEPTION 'QC_SUMMARY_WEEK_REQUIRED';
  END IF;

  v_week_end := p_week_start + 6;

  RETURN QUERY
  WITH active_stores AS (
    SELECT r.id, r.name
    FROM public.stores r
    WHERE r.is_active = TRUE
  ),
  template_counts AS (
    SELECT
      ar.id AS store_id,
      COUNT(*) FILTER (
        WHERE qt.is_active = TRUE
          AND (qt.is_global = TRUE OR qt.store_id = ar.id)
      )::INT AS template_count
    FROM active_stores ar
    LEFT JOIN public.qc_templates_store_bridge qt
      ON qt.is_active = TRUE
     AND (qt.is_global = TRUE OR qt.store_id = ar.id)
    GROUP BY ar.id
  ),
  checks AS (
    SELECT
      qc.store_id,
      COUNT(*)::BIGINT AS checked_count,
      COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
      MAX(qc.check_date) AS latest_check_date
    FROM public.qc_checks_store_bridge qc
    WHERE qc.check_date >= p_week_start
      AND qc.check_date <= v_week_end
    GROUP BY qc.store_id
  )
  SELECT
    ar.id AS store_id,
    ar.name AS restaurant_name,
    CASE
      WHEN COALESCE(tc.template_count, 0) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COALESCE(ch.checked_count, 0)::NUMERIC
        / (tc.template_count * 7)::NUMERIC * 100,
        2
      )
    END AS coverage,
    COALESCE(ch.fail_count, 0) AS fail_count,
    ch.latest_check_date
  FROM active_stores ar
  LEFT JOIN template_counts tc
    ON tc.store_id = ar.id
  LEFT JOIN checks ch
    ON ch.store_id = ar.id
  ORDER BY lower(ar.name);
END;
$function$

CREATE OR REPLACE FUNCTION public.get_qc_templates(p_restaurant_id uuid DEFAULT NULL::uuid, p_scope text DEFAULT 'visible'::text)
 RETURNS TABLE(id uuid, restaurant_id uuid, category text, criteria_text text, criteria_photo_url text, sort_order integer, is_global boolean, is_active boolean, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
  END IF;

  IF p_scope NOT IN ('visible', 'global') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SCOPE_INVALID';
  END IF;

  IF p_scope = 'global' THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  ELSE
    IF $1 IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.store_id <> $1 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    qt.id,
    qt.store_id,
    qt.category,
    qt.criteria_text,
    qt.criteria_photo_url,
    qt.sort_order,
    qt.is_global,
    qt.is_active,
    qt.created_at,
    qt.updated_at
  FROM public.qc_templates_store_bridge qt
  WHERE qt.is_active = TRUE
    AND (
      (p_scope = 'global' AND qt.is_global = TRUE)
      OR
      (
        p_scope = 'visible'
        AND (
          qt.is_global = TRUE
          OR qt.store_id = $1
        )
      )
    )
  ORDER BY qt.is_global DESC, lower(qt.category), qt.sort_order, qt.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_user_restaurant_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  SELECT store_id FROM public.users_store_bridge WHERE auth_id = auth.uid()
$function$

CREATE OR REPLACE FUNCTION public.get_user_store_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT public.get_user_store_id()
$function$

CREATE OR REPLACE FUNCTION public.on_payroll_store_submitted()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_brand_id UUID;
BEGIN
  SELECT brand_id
  INTO v_brand_id
  FROM public.stores
  WHERE id = ((to_jsonb(NEW) ->> (chr(115)||chr(116)||chr(111)||chr(114)||chr(101)||chr(95)||chr(105)||chr(100)))::uuid);

  INSERT INTO public.office_payroll_reviews_store_bridge (
    source_payroll_id,
    store_id,
    brand_id,
    period_start,
    period_end,
    status
  )
  VALUES (
    NEW.id,
    ((to_jsonb(NEW) ->> (chr(115)||chr(116)||chr(111)||chr(114)||chr(101)||chr(95)||chr(105)||chr(100)))::uuid),
    v_brand_id,
    NEW.period_start,
    NEW.period_end,
    'pending_review'
  )
  ON CONFLICT (source_payroll_id, period_start, period_end) DO NOTHING;

  RETURN NEW;
END;
$function$

CREATE OR REPLACE FUNCTION public.process_payment(p_order_id uuid, p_restaurant_id uuid, p_amount numeric, p_method text)
 RETURNS payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_order public.orders_store_bridge%ROWTYPE;
  v_payment public.payments_store_bridge%ROWTYPE;
  v_table_id UUID;
  v_is_revenue BOOLEAN;
  v_item RECORD;
  v_recipe RECORD;
  v_deduct_qty DECIMAL(12,3);
  v_expected_amount DECIMAL(12,2);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method NOT IN ('cash', 'card', 'pay', 'service') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  -- Lock order
  SELECT *
  INTO v_order
  FROM public.orders_store_bridge
  WHERE id = p_order_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF EXISTS (SELECT 1 FROM public.payments_store_bridge WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  -- Calculate expected amount EXCLUDING cancelled items
  SELECT COALESCE(SUM(unit_price * quantity), 0)
  INTO v_expected_amount
  FROM public.order_items_store_bridge
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

  IF v_expected_amount <= 0 THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  IF ROUND(COALESCE(p_amount, 0)::numeric, 2) <> ROUND(v_expected_amount, 2) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH';
  END IF;

  v_is_revenue := (p_method <> 'service');

  INSERT INTO public.payments_store_bridge (
    order_id,
    store_id,
    amount,
    method,
    processed_by,
    is_revenue
  )
  VALUES (
    p_order_id,
    $2,
    p_amount,
    p_method,
    auth.uid(),
    v_is_revenue
  )
  RETURNING * INTO v_payment;

  UPDATE public.orders_store_bridge
  SET status = 'completed',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE public.tables_store_bridge
    SET status = 'available',
        updated_at = now()
    WHERE id = v_table_id;
  END IF;

  -- Inventory deduction EXCLUDING cancelled items
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM public.order_items_store_bridge oi
    WHERE oi.order_id = p_order_id
      AND oi.menu_item_id IS NOT NULL
      AND oi.status <> 'cancelled'
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g
      FROM public.menu_recipes_store_bridge mr
      WHERE mr.menu_item_id = v_item.menu_item_id
        AND mr.store_id = $2
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE public.inventory_items_store_bridge
      SET current_stock = current_stock - v_deduct_qty,
          updated_at = now()
      WHERE id = v_recipe.ingredient_id
        AND store_id = $2;

      INSERT INTO public.inventory_transactions_store_bridge (
        store_id,
        ingredient_id,
        transaction_type,
        quantity_g,
        reference_type,
        reference_id,
        created_by
      )
      VALUES (
        $2,
        v_recipe.ingredient_id,
        'deduct',
        -v_deduct_qty,
        'order_item',
        v_item.order_item_id,
        auth.uid()
      );
    END LOOP;
  END LOOP;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', $2,
      'order_id', p_order_id,
      'amount', p_amount,
      'method', p_method,
      'is_revenue', v_is_revenue
    )
  );

  RETURN v_payment;
END;
$function$

CREATE OR REPLACE FUNCTION public.record_attendance_event(p_restaurant_id uuid, p_user_id uuid, p_type text, p_photo_url text DEFAULT NULL::text, p_photo_thumbnail_url text DEFAULT NULL::text)
 RETURNS TABLE(attendance_log_id uuid, restaurant_id uuid, user_id uuid, attendance_type text, photo_url text, photo_thumbnail_url text, logged_at timestamp with time zone, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_target_user public.users_store_bridge%ROWTYPE;
  v_log public.attendance_logs_store_bridge%ROWTYPE;
  v_photo_url TEXT := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_photo_thumbnail_url TEXT := NULLIF(btrim(COALESCE(p_photo_thumbnail_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_REQUIRED';
  END IF;

  IF p_type IS NULL OR p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_TYPE_INVALID';
  END IF;

  SELECT u.*
  INTO v_target_user
  FROM public.users_store_bridge u
  WHERE u.id = p_user_id
    AND u.store_id = $1
    AND u.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_NOT_FOUND';
  END IF;

  INSERT INTO public.attendance_logs_store_bridge (
    store_id,
    user_id,
    type,
    photo_url,
    photo_thumbnail_url,
    logged_at
  )
  VALUES (
    $1,
    p_user_id,
    p_type,
    v_photo_url,
    COALESCE(v_photo_thumbnail_url, v_photo_url),
    now()
  )
  RETURNING * INTO v_log;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attendance_event_recorded',
    'attendance_logs',
    v_log.id,
    jsonb_build_object(
      'store_id', $1,
      'user_id', p_user_id,
      'attendance_type', p_type,
      'logged_at', v_log.logged_at,
      'photo_url', v_log.photo_url,
      'photo_thumbnail_url', v_log.photo_thumbnail_url
    )
  );

  RETURN QUERY
  SELECT
    v_log.id AS attendance_log_id,
    v_log.store_id,
    v_log.user_id,
    v_log.type AS attendance_type,
    v_log.photo_url,
    v_log.photo_thumbnail_url,
    v_log.logged_at,
    v_log.created_at;
END;
$function$

CREATE OR REPLACE FUNCTION public.record_inventory_waste(p_restaurant_id uuid, p_ingredient_id uuid, p_quantity_g numeric, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor       public.users_store_bridge%ROWTYPE;
  v_ingredient  public.inventory_items_store_bridge%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items_store_bridge
  WHERE id = p_ingredient_id
    AND store_id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) - p_quantity_g;

  -- Allow negative stock (real-world discrepancy) but warn via audit
  UPDATE public.inventory_items_store_bridge
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND store_id = $1;

  -- Transaction record (negative quantity for waste)
  INSERT INTO public.inventory_transactions_store_bridge (
    store_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    $1, p_ingredient_id, 'waste',
    -p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_waste_recorded',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', $1,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note,
      'went_negative', v_new_stock < 0
    )
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(p_restaurant_id uuid)
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$function$

CREATE OR REPLACE FUNCTION public.restock_inventory_item(p_restaurant_id uuid, p_ingredient_id uuid, p_quantity_g numeric, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor       public.users_store_bridge%ROWTYPE;
  v_ingredient  public.inventory_items_store_bridge%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items_store_bridge
  WHERE id = p_ingredient_id
    AND store_id = $1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) + p_quantity_g;

  -- Atomic stock update
  UPDATE public.inventory_items_store_bridge
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND store_id = $1;

  -- Transaction record
  INSERT INTO public.inventory_transactions_store_bridge (
    store_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    $1, p_ingredient_id, 'restock',
    p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_restocked',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', $1,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note
    )
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.transfer_order_table(p_order_id uuid, p_restaurant_id uuid, p_new_table_id uuid)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_order public.orders_store_bridge%ROWTYPE;
  v_old_table_id UUID;
  v_new_table public.tables_store_bridge%ROWTYPE;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Lock order
  SELECT *
  INTO v_order
  FROM public.orders_store_bridge
  WHERE id = p_order_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  v_old_table_id := v_order.table_id;

  -- Cannot transfer to same table
  IF v_old_table_id = p_new_table_id THEN
    RAISE EXCEPTION 'TRANSFER_SAME_TABLE';
  END IF;

  -- Lock and validate new table
  SELECT *
  INTO v_new_table
  FROM public.tables_store_bridge
  WHERE id = p_new_table_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_new_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  -- Move order to new table
  UPDATE public.orders_store_bridge
  SET table_id = p_new_table_id,
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- Occupy new table
  UPDATE public.tables_store_bridge
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_new_table_id;

  -- Release old table (if it had one)
  IF v_old_table_id IS NOT NULL THEN
    UPDATE public.tables_store_bridge
    SET status = 'available',
        updated_at = now()
    WHERE id = v_old_table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'transfer_order_table',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', $2,
      'old_table_id', v_old_table_id,
      'new_table_id', p_new_table_id,
      'new_table_number', v_new_table.table_number
    )
  );

  RETURN v_order;
END;
$function$

CREATE OR REPLACE FUNCTION public.update_inventory_item(p_item_id uuid, p_restaurant_id uuid, p_patch jsonb)
 RETURNS inventory_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_existing public.inventory_items_store_bridge%ROWTYPE;
  v_updated public.inventory_items_store_bridge%ROWTYPE;
  v_supported_keys CONSTANT TEXT[] := ARRAY[
    'name',
    'unit',
    'current_stock',
    'reorder_point',
    'cost_per_unit',
    'supplier_name'
  ];
  v_key TEXT;
  v_name TEXT;
  v_unit TEXT;
  v_current_stock DECIMAL(12,3);
  v_reorder_point DECIMAL(12,3);
  v_cost_per_unit DECIMAL(12,2);
  v_supplier_name TEXT;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(p_patch) AS k(key)
    WHERE k.key = ANY(v_supported_keys)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_EMPTY';
  END IF;

  FOR v_key IN
    SELECT key
    FROM jsonb_object_keys(p_patch) AS k(key)
  LOOP
    IF NOT (v_key = ANY(v_supported_keys)) THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  SELECT *
  INTO v_existing
  FROM public.inventory_items_store_bridge
  WHERE id = p_item_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND';
  END IF;

  v_name := v_existing.name;
  v_unit := v_existing.unit;
  v_current_stock := v_existing.current_stock;
  v_reorder_point := v_existing.reorder_point;
  v_cost_per_unit := v_existing.cost_per_unit;
  v_supplier_name := v_existing.supplier_name;

  IF p_patch ? 'name' THEN
    v_name := btrim(COALESCE(p_patch->>'name', ''));
    IF v_name = '' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
    END IF;
  END IF;

  IF p_patch ? 'unit' THEN
    v_unit := btrim(COALESCE(p_patch->>'unit', ''));
    IF v_unit NOT IN ('g', 'ml', 'ea') THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'current_stock' THEN
    IF jsonb_typeof(p_patch->'current_stock') = 'null' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_REQUIRED';
    END IF;
    v_current_stock := (p_patch->>'current_stock')::DECIMAL(12,3);
    IF v_current_stock < 0 THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'reorder_point' THEN
    IF jsonb_typeof(p_patch->'reorder_point') = 'null' THEN
      v_reorder_point := NULL;
    ELSE
      v_reorder_point := (p_patch->>'reorder_point')::DECIMAL(12,3);
      IF v_reorder_point < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'cost_per_unit' THEN
    IF jsonb_typeof(p_patch->'cost_per_unit') = 'null' THEN
      v_cost_per_unit := NULL;
    ELSE
      v_cost_per_unit := (p_patch->>'cost_per_unit')::DECIMAL(12,2);
      IF v_cost_per_unit < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'supplier_name' THEN
    IF jsonb_typeof(p_patch->'supplier_name') = 'null' THEN
      v_supplier_name := NULL;
    ELSE
      v_supplier_name := NULLIF(btrim(p_patch->>'supplier_name'), '');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items_store_bridge ii
    WHERE ii.store_id = $2
      AND ii.id <> p_item_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  IF v_existing.name IS DISTINCT FROM v_name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;
  IF v_existing.unit IS DISTINCT FROM v_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'unit');
    v_old_values := v_old_values || jsonb_build_object('unit', v_existing.unit);
    v_new_values := v_new_values || jsonb_build_object('unit', v_unit);
  END IF;
  IF v_existing.current_stock IS DISTINCT FROM v_current_stock THEN
    v_changed_fields := array_append(v_changed_fields, 'current_stock');
    v_old_values := v_old_values || jsonb_build_object('current_stock', v_existing.current_stock);
    v_new_values := v_new_values || jsonb_build_object('current_stock', v_current_stock);
  END IF;
  IF v_existing.reorder_point IS DISTINCT FROM v_reorder_point THEN
    v_changed_fields := array_append(v_changed_fields, 'reorder_point');
    v_old_values := v_old_values || jsonb_build_object('reorder_point', v_existing.reorder_point);
    v_new_values := v_new_values || jsonb_build_object('reorder_point', v_reorder_point);
  END IF;
  IF v_existing.cost_per_unit IS DISTINCT FROM v_cost_per_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'cost_per_unit');
    v_old_values := v_old_values || jsonb_build_object('cost_per_unit', v_existing.cost_per_unit);
    v_new_values := v_new_values || jsonb_build_object('cost_per_unit', v_cost_per_unit);
  END IF;
  IF v_existing.supplier_name IS DISTINCT FROM v_supplier_name THEN
    v_changed_fields := array_append(v_changed_fields, 'supplier_name');
    v_old_values := v_old_values || jsonb_build_object('supplier_name', v_existing.supplier_name);
    v_new_values := v_new_values || jsonb_build_object('supplier_name', v_supplier_name);
  END IF;

  IF coalesce(array_length(v_changed_fields, 1), 0) = 0 THEN
    RETURN v_existing;
  END IF;

  UPDATE public.inventory_items_store_bridge
  SET name = v_name,
      unit = v_unit,
      current_stock = v_current_stock,
      reorder_point = v_reorder_point,
      cost_per_unit = v_cost_per_unit,
      supplier_name = v_supplier_name,
      updated_at = now()
  WHERE id = p_item_id
    AND store_id = $2
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_updated',
    'inventory_items',
    v_updated.id,
    jsonb_build_object(
      'store_id', $2,
      'changed_fields', to_jsonb(v_changed_fields),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.update_order_item_status(p_item_id uuid, p_restaurant_id uuid, p_new_status text)
 RETURNS order_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_item public.order_items_store_bridge%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM public.order_items_store_bridge
  WHERE id = p_item_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM public.orders_store_bridge
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Cancelled items are final — no further transitions
  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_IS_CANCELLED';
  END IF;

  IF NOT (
    (v_item.status = 'pending' AND p_new_status = 'preparing')
    OR (v_item.status = 'preparing' AND p_new_status = 'ready')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;

  UPDATE public.order_items_store_bridge
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', $2,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$function$

CREATE OR REPLACE FUNCTION public.update_qc_followup_status(p_followup_id uuid, p_restaurant_id uuid, p_status text, p_resolution_notes text DEFAULT NULL::text)
 RETURNS qc_followups
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor    public.users_store_bridge%ROWTYPE;
  v_existing public.qc_followups_store_bridge%ROWTYPE;
  v_updated  public.qc_followups_store_bridge%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users_store_bridge
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $2 THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('open', 'in_progress', 'resolved') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_STATUS_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.qc_followups_store_bridge
  WHERE id = p_followup_id
    AND store_id = $2
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FOUND';
  END IF;

  UPDATE public.qc_followups_store_bridge
  SET status = p_status,
      resolution_notes = CASE
        WHEN p_resolution_notes IS NOT NULL
        THEN NULLIF(btrim(p_resolution_notes), '')
        ELSE resolution_notes
      END,
      updated_at = now(),
      resolved_at = CASE
        WHEN p_status = 'resolved' THEN now()
        ELSE NULL
      END
  WHERE id = p_followup_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_status_updated',
    'qc_followups',
    v_updated.id,
    jsonb_build_object(
      'store_id', $2,
      'old_status', v_existing.status,
      'new_status', p_status,
      'resolution_notes', v_updated.resolution_notes
    )
  );

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.update_qc_template(p_template_id uuid, p_patch jsonb)
 RETURNS qc_templates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_existing public.qc_templates_store_bridge%ROWTYPE;
  v_updated public.qc_templates_store_bridge%ROWTYPE;
  v_patch JSONB := COALESCE(p_patch, '{}'::JSONB);
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_key TEXT;
  v_value JSONB;
  v_category TEXT;
  v_text TEXT;
  v_photo TEXT;
  v_sort_order INT;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(v_patch) <> 'object' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_INVALID';
  END IF;

  IF v_patch = '{}'::JSONB THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_EMPTY';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates_store_bridge qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.store_id <> v_actor.store_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    IF v_key NOT IN ('category', 'criteria_text', 'criteria_photo_url', 'sort_order') THEN
      RAISE EXCEPTION 'QC_TEMPLATE_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  v_category := v_existing.category;
  v_text := v_existing.criteria_text;
  v_photo := v_existing.criteria_photo_url;
  v_sort_order := v_existing.sort_order;

  IF v_patch ? 'category' THEN
    v_category := NULLIF(btrim(v_patch->>'category'), '');
    IF v_category IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
    END IF;
    IF v_category IS DISTINCT FROM v_existing.category THEN
      v_changed_fields := array_append(v_changed_fields, 'category');
      v_old_values := v_old_values || jsonb_build_object('category', v_existing.category);
      v_new_values := v_new_values || jsonb_build_object('category', v_category);
    END IF;
  END IF;

  IF v_patch ? 'criteria_text' THEN
    v_text := NULLIF(btrim(v_patch->>'criteria_text'), '');
    IF v_text IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
    END IF;
    IF v_text IS DISTINCT FROM v_existing.criteria_text THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_text');
      v_old_values := v_old_values || jsonb_build_object('criteria_text', v_existing.criteria_text);
      v_new_values := v_new_values || jsonb_build_object('criteria_text', v_text);
    END IF;
  END IF;

  IF v_patch ? 'criteria_photo_url' THEN
    v_photo := NULLIF(btrim(COALESCE(v_patch->>'criteria_photo_url', '')), '');
    IF v_photo IS DISTINCT FROM v_existing.criteria_photo_url THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_photo_url');
      v_old_values := v_old_values || jsonb_build_object('criteria_photo_url', v_existing.criteria_photo_url);
      v_new_values := v_new_values || jsonb_build_object('criteria_photo_url', v_photo);
    END IF;
  END IF;

  IF v_patch ? 'sort_order' THEN
    BEGIN
      v_sort_order := (v_patch->>'sort_order')::INT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END;
    IF v_sort_order < 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END IF;
    IF v_sort_order IS DISTINCT FROM v_existing.sort_order THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_order');
      v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
      v_new_values := v_new_values || jsonb_build_object('sort_order', v_sort_order);
    END IF;
  END IF;

  UPDATE public.qc_templates_store_bridge
  SET category = v_category,
      criteria_text = v_text,
      criteria_photo_url = v_photo,
      sort_order = v_sort_order,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'qc_template_updated',
      'qc_templates',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'is_global', v_updated.is_global,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.upsert_inventory_recipe_line(p_restaurant_id uuid, p_menu_item_id uuid, p_ingredient_id uuid, p_quantity_g numeric)
 RETURNS TABLE(recipe_id uuid, restaurant_id uuid, menu_item_id uuid, menu_item_name text, ingredient_id uuid, ingredient_name text, ingredient_unit text, quantity_g numeric, last_updated timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_menu_item public.menu_items_store_bridge%ROWTYPE;
  v_ingredient public.inventory_items_store_bridge%ROWTYPE;
  v_existing public.menu_recipes_store_bridge%ROWTYPE;
  v_recipe public.menu_recipes_store_bridge%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_REQUIRED';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_QUANTITY_INVALID';
  END IF;

  SELECT mi.*
  INTO v_menu_item
  FROM public.menu_items_store_bridge mi
  WHERE mi.id = p_menu_item_id
    AND mi.store_id = $1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items_store_bridge ii
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = $1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT mr.*
  INTO v_existing
  FROM public.menu_recipes_store_bridge mr
  WHERE mr.store_id = $1
    AND mr.menu_item_id = p_menu_item_id
    AND mr.ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.quantity_g IS DISTINCT FROM p_quantity_g THEN
      v_changed_fields := ARRAY['quantity_g'];
      v_old_values := jsonb_build_object('quantity_g', v_existing.quantity_g);
      v_new_values := jsonb_build_object('quantity_g', p_quantity_g);

      UPDATE public.menu_recipes_store_bridge mr
      SET quantity_g = p_quantity_g,
          updated_at = now()
      WHERE mr.id = v_existing.id
      RETURNING mr.* INTO v_recipe;

      INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(),
        'inventory_recipe_upserted',
        'menu_recipes',
        v_recipe.id,
        jsonb_build_object(
          'operation', 'update',
          'store_id', $1,
          'menu_item_id', p_menu_item_id,
          'ingredient_id', p_ingredient_id,
          'changed_fields', to_jsonb(v_changed_fields),
          'old_values', v_old_values,
          'new_values', v_new_values
        )
      );
    ELSE
      v_recipe := v_existing;
    END IF;
  ELSE
    INSERT INTO public.menu_recipes_store_bridge (
      store_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    )
    VALUES (
      $1,
      p_menu_item_id,
      p_ingredient_id,
      p_quantity_g,
      now()
    )
    RETURNING * INTO v_recipe;

    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'inventory_recipe_upserted',
      'menu_recipes',
      v_recipe.id,
      jsonb_build_object(
        'operation', 'create',
        'store_id', $1,
        'menu_item_id', p_menu_item_id,
        'ingredient_id', p_ingredient_id,
        'new_values', jsonb_build_object(
          'quantity_g', v_recipe.quantity_g
        )
      )
    );
  END IF;

  RETURN QUERY
  SELECT
    v_recipe.id AS recipe_id,
    v_recipe.store_id,
    v_recipe.menu_item_id,
    v_menu_item.name AS menu_item_name,
    v_recipe.ingredient_id,
    v_ingredient.name AS ingredient_name,
    v_ingredient.unit AS ingredient_unit,
    v_recipe.quantity_g,
    v_recipe.updated_at AS last_updated;
END;
$function$

CREATE OR REPLACE FUNCTION public.upsert_qc_check(p_restaurant_id uuid, p_template_id uuid, p_check_date date, p_result text, p_evidence_photo_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_checked_by uuid DEFAULT NULL::uuid)
 RETURNS qc_checks
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor public.users_store_bridge%ROWTYPE;
  v_can_check BOOLEAN;
  v_template public.qc_templates_store_bridge%ROWTYPE;
  v_existing public.qc_checks_store_bridge%ROWTYPE;
  v_saved public.qc_checks_store_bridge%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_evidence_photo_url, '')), '');
  v_checked_by UUID := COALESCE(p_checked_by, auth.uid());
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users_store_bridge u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> $1 THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_REQUIRED';
  END IF;

  IF p_check_date IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_DATE_REQUIRED';
  END IF;

  IF p_result NOT IN ('pass', 'fail', 'na') THEN
    RAISE EXCEPTION 'QC_CHECK_RESULT_INVALID';
  END IF;

  IF v_checked_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_ACTOR_INVALID';
  END IF;

  SELECT qt.*
  INTO v_template
  FROM public.qc_templates_store_bridge qt
  WHERE qt.id = p_template_id
    AND qt.is_active = TRUE
    AND (
      qt.is_global = TRUE
      OR qt.store_id = $1
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_NOT_FOUND';
  END IF;

  SELECT qc.*
  INTO v_existing
  FROM public.qc_checks_store_bridge qc
  WHERE qc.template_id = p_template_id
    AND qc.check_date = p_check_date
  FOR UPDATE;

  INSERT INTO public.qc_checks_store_bridge (
    store_id,
    template_id,
    check_date,
    checked_by,
    result,
    evidence_photo_url,
    note
  )
  VALUES (
    $1,
    p_template_id,
    p_check_date,
    v_checked_by,
    p_result,
    v_photo,
    v_note
  )
  ON CONFLICT (template_id, check_date)
  DO UPDATE SET
    store_id = EXCLUDED.store_id,
    checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result,
    evidence_photo_url = EXCLUDED.evidence_photo_url,
    note = EXCLUDED.note
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_check_upserted',
    'qc_checks',
    v_saved.id,
    jsonb_build_object(
      'store_id', $1,
      'template_id', p_template_id,
      'check_date', p_check_date,
      'result', p_result,
      'evidence_photo_url', v_photo,
      'note', v_note,
      'previous_check', CASE
        WHEN v_existing.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'result', v_existing.result,
          'evidence_photo_url', v_existing.evidence_photo_url,
          'note', v_existing.note,
          'checked_by', v_existing.checked_by
        )
      END
    )
  );

  RETURN v_saved;
END;
$function$

-- Section B - Views

DROP VIEW IF EXISTS public.public_menu_items CASCADE;

DROP VIEW IF EXISTS public.public_restaurant_profiles CASCADE;

DROP VIEW IF EXISTS public.v_brand_kpi CASCADE;

DROP VIEW IF EXISTS public.v_daily_revenue_by_channel CASCADE;

DROP VIEW IF EXISTS public.v_external_store_overview CASCADE;

DROP VIEW IF EXISTS public.v_external_store_sales CASCADE;

DROP VIEW IF EXISTS public.v_inventory_status CASCADE;

DROP VIEW IF EXISTS public.v_quality_monitoring CASCADE;

DROP VIEW IF EXISTS public.v_settlement_summary CASCADE;

DROP VIEW IF EXISTS public.v_store_attendance_summary CASCADE;

DROP VIEW IF EXISTS public.v_store_daily_sales CASCADE;

CREATE OR REPLACE VIEW public.public_menu_items AS
 SELECT mi.id AS external_menu_item_id,
    mi.store_id,
    r.slug AS restaurant_slug,
    r.store_type,
    mc.name AS category_name,
    mi.name,
    mi.description,
    mi.price,
    r.operation_mode
   FROM ((public.menu_items_store_bridge mi
     JOIN public.stores r ON ((r.id = mi.store_id)))
     LEFT JOIN public.menu_categories_store_bridge mc ON ((mc.id = mi.category_id)))
  WHERE ((mi.is_available = true) AND (mi.is_visible_public = true));;

CREATE OR REPLACE VIEW public.public_restaurant_profiles AS
 SELECT r.id,
    r.slug,
    r.name,
    r.address,
    r.operation_mode,
    r.per_person_charge,
    r.is_active,
    r.store_type,
    r.brand_id,
    b.name AS brand_name,
    r.created_at
   FROM (public.stores r
     LEFT JOIN brands b ON ((b.id = r.brand_id)))
  WHERE (r.is_active = true);;

CREATE OR REPLACE VIEW public.v_brand_kpi AS
 SELECT b.id AS brand_id,
    b.code AS brand_code,
    b.name AS brand_name,
    count(DISTINCT r.id) AS store_count,
    count(DISTINCT u.id) FILTER (WHERE (u.is_active = true)) AS active_staff_count,
    ( SELECT COALESCE(sum(p.amount), (0)::numeric) AS "coalesce"
           FROM (public.payments_store_bridge p
             JOIN public.stores r2 ON ((r2.id = p.store_id)))
          WHERE ((r2.brand_id = b.id) AND (r2.store_type = 'direct'::text) AND (p.is_revenue = true) AND (p.created_at >= date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))))) AS mtd_revenue,
    ( SELECT count(DISTINCT p.order_id) AS count
           FROM (public.payments_store_bridge p
             JOIN public.stores r2 ON ((r2.id = p.store_id)))
          WHERE ((r2.brand_id = b.id) AND (r2.store_type = 'direct'::text) AND (p.is_revenue = true) AND (p.created_at >= date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))))) AS mtd_order_count
   FROM ((brands b
     LEFT JOIN public.stores r ON (((r.brand_id = b.id) AND (r.store_type = 'direct'::text))))
     LEFT JOIN public.users_store_bridge u ON ((u.store_id = r.id)))
  GROUP BY b.id, b.code, b.name;;

CREATE OR REPLACE VIEW public.v_daily_revenue_by_channel AS
 SELECT COALESCE(pos.store_id, del.store_id) AS store_id,
    COALESCE(pos.sale_date, del.sale_date) AS sale_date,
    COALESCE(pos.dine_in_revenue, (0)::numeric) AS dine_in_revenue,
    COALESCE(pos.dine_in_orders, (0)::bigint) AS dine_in_orders,
    COALESCE(pos.takeaway_revenue, (0)::numeric) AS takeaway_revenue,
    COALESCE(pos.takeaway_orders, (0)::bigint) AS takeaway_orders,
    COALESCE(del.delivery_revenue, (0)::numeric) AS delivery_revenue,
    COALESCE(del.delivery_orders, (0)::bigint) AS delivery_orders,
    ((COALESCE(pos.dine_in_revenue, (0)::numeric) + COALESCE(pos.takeaway_revenue, (0)::numeric)) + COALESCE(del.delivery_revenue, (0)::numeric)) AS total_revenue
   FROM (( SELECT o.store_id,
            ((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))::date AS sale_date,
            sum(
                CASE
                    WHEN (o.sales_channel = 'dine_in'::text) THEN p.amount
                    ELSE (0)::numeric
                END) AS dine_in_revenue,
            count(
                CASE
                    WHEN (o.sales_channel = 'dine_in'::text) THEN 1
                    ELSE NULL::integer
                END) AS dine_in_orders,
            sum(
                CASE
                    WHEN (o.sales_channel = 'takeaway'::text) THEN p.amount
                    ELSE (0)::numeric
                END) AS takeaway_revenue,
            count(
                CASE
                    WHEN (o.sales_channel = 'takeaway'::text) THEN 1
                    ELSE NULL::integer
                END) AS takeaway_orders
           FROM (public.orders_store_bridge o
             JOIN public.payments_store_bridge p ON ((p.order_id = o.id)))
          WHERE ((o.status = 'completed'::text) AND (p.is_revenue = true))
          GROUP BY o.store_id, (((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))::date)) pos
     FULL JOIN ( SELECT public.external_sales_store_bridge.store_id,
            ((public.external_sales_store_bridge.completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))::date AS sale_date,
            sum(public.external_sales_store_bridge.gross_amount) AS delivery_revenue,
            count(*) AS delivery_orders
           FROM public.external_sales_store_bridge
          WHERE ((public.external_sales_store_bridge.is_revenue = true) AND (public.external_sales_store_bridge.order_status = 'completed'::text))
          GROUP BY public.external_sales_store_bridge.store_id, (((public.external_sales_store_bridge.completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text))::date)) del ON (((pos.store_id = del.store_id) AND (pos.sale_date = del.sale_date))));;

CREATE OR REPLACE VIEW public.v_external_store_overview AS
 SELECT r.id AS store_id,
    r.name AS store_name,
    b.name AS brand_name,
    r.brand_id,
    r.is_active,
    r.created_at AS registered_at,
    ( SELECT count(*) AS count
           FROM public.users_store_bridge u
          WHERE ((u.store_id = r.id) AND (u.is_active = true))) AS active_staff,
    ( SELECT COALESCE(sum(p.amount), (0)::numeric) AS "coalesce"
           FROM public.payments_store_bridge p
          WHERE ((p.store_id = r.id) AND (p.is_revenue = true) AND (p.created_at >= date_trunc('month'::text, now())))) AS mtd_sales,
    ( SELECT count(DISTINCT o.id) AS count
           FROM public.orders_store_bridge o
          WHERE ((o.store_id = r.id) AND (o.created_at >= date_trunc('month'::text, now())))) AS mtd_order_count
   FROM (public.stores r
     LEFT JOIN brands b ON ((b.id = r.brand_id)))
  WHERE (r.store_type = 'external'::text);;

CREATE OR REPLACE VIEW public.v_external_store_sales AS
 SELECT r.id AS store_id,
    r.brand_id,
    b.name AS brand_name,
    r.name AS store_name,
    date((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)) AS sale_date,
    count(DISTINCT p.order_id) AS order_count,
    sum(
        CASE
            WHEN p.is_revenue THEN p.amount
            ELSE (0)::numeric
        END) AS revenue,
    sum(
        CASE
            WHEN (NOT p.is_revenue) THEN p.amount
            ELSE (0)::numeric
        END) AS service_amount
   FROM ((public.payments_store_bridge p
     JOIN public.stores r ON ((r.id = p.store_id)))
     LEFT JOIN brands b ON ((b.id = r.brand_id)))
  WHERE (r.store_type = 'external'::text)
  GROUP BY r.id, r.brand_id, b.name, r.name, (date((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)));;

CREATE OR REPLACE VIEW public.v_inventory_status AS
 SELECT ii.id AS item_id,
    ii.store_id AS store_id,
    r.brand_id,
    r.name AS store_name,
    ii.name AS item_name,
    ii.current_stock,
    ii.unit,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
        CASE
            WHEN ((ii.reorder_point IS NOT NULL) AND (ii.current_stock <= ii.reorder_point)) THEN true
            ELSE false
        END AS needs_reorder,
    ii.updated_at AS last_updated
   FROM (public.inventory_items_store_bridge ii
     JOIN public.stores r ON ((r.id = ii.store_id)))
  WHERE (r.store_type = 'direct'::text);;

CREATE OR REPLACE VIEW public.v_quality_monitoring AS
 SELECT qc.id AS check_id,
    qc.store_id AS store_id,
    r.brand_id,
    r.name AS store_name,
    qt.category,
    qt.criteria_text,
    qc.check_date,
    qc.result,
    qc.evidence_photo_url,
    qc.note,
    qc.checked_by,
    qc.created_at
   FROM ((public.qc_checks_store_bridge qc
     JOIN public.qc_templates_store_bridge qt ON ((qt.id = qc.template_id)))
     JOIN public.stores r ON ((r.id = qc.store_id)))
  WHERE (r.store_type = 'direct'::text);;

CREATE OR REPLACE VIEW public.v_settlement_summary AS
 SELECT id,
    store_id,
    period_label,
    period_start,
    period_end,
    gross_total,
    total_deductions,
    net_settlement,
    status,
    received_at,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('item_type', dsi.item_type, 'amount', dsi.amount, 'description', dsi.description, 'reference_rate', dsi.reference_rate) ORDER BY dsi.item_type) AS jsonb_agg
           FROM delivery_settlement_items dsi
          WHERE (dsi.settlement_id = ds.id)), '[]'::jsonb) AS items,
    ( SELECT count(*) AS count
           FROM public.external_sales_store_bridge es
          WHERE ((es.settlement_id = ds.id) AND (es.is_revenue = true))) AS order_count
   FROM public.delivery_settlements_store_bridge ds;;

CREATE OR REPLACE VIEW public.v_store_attendance_summary AS
 SELECT al.store_id AS store_id,
    r.brand_id,
    al.user_id,
    COALESCE(u.full_name, u.role) AS employee_name,
    u.role AS employee_role,
    date((al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)) AS work_date,
    min(
        CASE
            WHEN (al.type = 'clock_in'::text) THEN al.logged_at
            ELSE NULL::timestamp with time zone
        END) AS first_clock_in,
    max(
        CASE
            WHEN (al.type = 'clock_out'::text) THEN al.logged_at
            ELSE NULL::timestamp with time zone
        END) AS last_clock_out,
    count(
        CASE
            WHEN (al.type = 'clock_in'::text) THEN 1
            ELSE NULL::integer
        END) AS clock_in_count,
    count(
        CASE
            WHEN (al.type = 'clock_out'::text) THEN 1
            ELSE NULL::integer
        END) AS clock_out_count
   FROM ((public.attendance_logs_store_bridge al
     JOIN public.stores r ON ((r.id = al.store_id)))
     JOIN public.users_store_bridge u ON ((u.id = al.user_id)))
  WHERE (r.store_type = 'direct'::text)
  GROUP BY al.store_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role, (date((al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)));;

CREATE OR REPLACE VIEW public.v_store_daily_sales AS
 SELECT r.id AS store_id,
    r.brand_id,
    b.name AS brand_name,
    r.name AS store_name,
    date((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)) AS sale_date,
    count(DISTINCT p.order_id) AS order_count,
    sum(
        CASE
            WHEN p.is_revenue THEN p.amount
            ELSE (0)::numeric
        END) AS revenue,
    sum(
        CASE
            WHEN (NOT p.is_revenue) THEN p.amount
            ELSE (0)::numeric
        END) AS service_amount
   FROM ((public.payments_store_bridge p
     JOIN public.stores r ON ((r.id = p.store_id)))
     LEFT JOIN brands b ON ((b.id = r.brand_id)))
  WHERE (r.store_type = 'direct'::text)
  GROUP BY r.id, r.brand_id, b.name, r.name, (date((p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'::text)));;

CREATE OR REPLACE VIEW public.public_store_profiles AS
SELECT *
FROM public.public_restaurant_profiles;

-- Section C - RLS policies

-- attendance_logs

DROP POLICY IF EXISTS attendance_logs_policy ON public.attendance_logs;

CREATE POLICY attendance_logs_policy ON public.attendance_logs
AS PERMISSIVE
FOR ALL TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())))
WITH CHECK ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- delivery_settlement_items

DROP POLICY IF EXISTS settlement_items_insert ON public.delivery_settlement_items;

DROP POLICY IF EXISTS settlement_items_read ON public.delivery_settlement_items;

CREATE POLICY settlement_items_insert ON public.delivery_settlement_items
AS PERMISSIVE
FOR INSERT TO public
WITH CHECK ((EXISTS ( SELECT 1
   FROM delivery_settlements ds
  WHERE ((ds.id = delivery_settlement_items.settlement_id) AND (ds.restaurant_id = get_user_store_id())))));

CREATE POLICY settlement_items_read ON public.delivery_settlement_items
AS PERMISSIVE
FOR SELECT TO public
USING ((EXISTS ( SELECT 1
   FROM delivery_settlements ds
  WHERE ((ds.id = delivery_settlement_items.settlement_id) AND (is_super_admin() OR (ds.restaurant_id = get_user_store_id()))))));

-- delivery_settlements

DROP POLICY IF EXISTS delivery_settlements_confirm ON public.delivery_settlements;

DROP POLICY IF EXISTS delivery_settlements_read ON public.delivery_settlements;

CREATE POLICY delivery_settlements_confirm ON public.delivery_settlements
AS PERMISSIVE
FOR UPDATE TO public
USING (((restaurant_id = get_user_store_id()) AND has_any_role(ARRAY['admin'::text, 'super_admin'::text])))
WITH CHECK ((restaurant_id = get_user_store_id()));

CREATE POLICY delivery_settlements_read ON public.delivery_settlements
AS PERMISSIVE
FOR SELECT TO public
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- external_sales

DROP POLICY IF EXISTS external_sales_read ON public.external_sales;

CREATE POLICY external_sales_read ON public.external_sales
AS PERMISSIVE
FOR SELECT TO public
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- inventory_items

DROP POLICY IF EXISTS inventory_items_policy ON public.inventory_items;

CREATE POLICY inventory_items_policy ON public.inventory_items
AS PERMISSIVE
FOR ALL TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())))
WITH CHECK ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- inventory_physical_counts

DROP POLICY IF EXISTS restaurant_isolation ON public.inventory_physical_counts;

CREATE POLICY restaurant_isolation ON public.inventory_physical_counts
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])))
WITH CHECK (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- inventory_transactions

DROP POLICY IF EXISTS restaurant_isolation ON public.inventory_transactions;

CREATE POLICY restaurant_isolation ON public.inventory_transactions
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])))
WITH CHECK (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- menu_categories

DROP POLICY IF EXISTS menu_categories_select_policy ON public.menu_categories;

CREATE POLICY menu_categories_select_policy ON public.menu_categories
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- menu_items

DROP POLICY IF EXISTS menu_items_select_policy ON public.menu_items;

CREATE POLICY menu_items_select_policy ON public.menu_items
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- menu_recipes

DROP POLICY IF EXISTS restaurant_isolation ON public.menu_recipes;

CREATE POLICY restaurant_isolation ON public.menu_recipes
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])))
WITH CHECK (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- office_payroll_reviews

DROP POLICY IF EXISTS office_payroll_reviews_pos_update ON public.office_payroll_reviews;

DROP POLICY IF EXISTS office_payroll_reviews_scoped_select ON public.office_payroll_reviews;

CREATE POLICY office_payroll_reviews_pos_update ON public.office_payroll_reviews
AS PERMISSIVE
FOR UPDATE TO authenticated
USING ((has_any_role(ARRAY['admin'::text, 'super_admin'::text]) AND (is_super_admin() OR (restaurant_id = get_user_store_id()))))
WITH CHECK ((has_any_role(ARRAY['admin'::text, 'super_admin'::text]) AND (is_super_admin() OR (restaurant_id = get_user_store_id()))));

CREATE POLICY office_payroll_reviews_scoped_select ON public.office_payroll_reviews
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- order_items

DROP POLICY IF EXISTS order_items_policy ON public.order_items;

CREATE POLICY order_items_policy ON public.order_items
AS PERMISSIVE
FOR ALL TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())))
WITH CHECK ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- orders

DROP POLICY IF EXISTS orders_policy ON public.orders;

CREATE POLICY orders_policy ON public.orders
AS PERMISSIVE
FOR ALL TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())))
WITH CHECK ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- payments

DROP POLICY IF EXISTS payments_policy ON public.payments;

CREATE POLICY payments_policy ON public.payments
AS PERMISSIVE
FOR ALL TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())))
WITH CHECK ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- payroll_records

DROP POLICY IF EXISTS restaurant_isolation ON public.payroll_records;

CREATE POLICY restaurant_isolation ON public.payroll_records
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- qc_checks

DROP POLICY IF EXISTS restaurant_isolation ON public.qc_checks;

CREATE POLICY restaurant_isolation ON public.qc_checks
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- qc_followups

DROP POLICY IF EXISTS qc_followups_restaurant_isolation ON public.qc_followups;

CREATE POLICY qc_followups_restaurant_isolation ON public.qc_followups
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- qc_templates

DROP POLICY IF EXISTS qc_templates_delete ON public.qc_templates;

DROP POLICY IF EXISTS qc_templates_insert ON public.qc_templates;

DROP POLICY IF EXISTS qc_templates_select ON public.qc_templates;

DROP POLICY IF EXISTS qc_templates_update ON public.qc_templates;

CREATE POLICY qc_templates_delete ON public.qc_templates
AS PERMISSIVE
FOR DELETE TO public
USING ((has_any_role(ARRAY['super_admin'::text]) OR (has_any_role(ARRAY['admin'::text]) AND (is_global = false) AND (restaurant_id = get_user_store_id()))));

CREATE POLICY qc_templates_insert ON public.qc_templates
AS PERMISSIVE
FOR INSERT TO public
WITH CHECK ((has_any_role(ARRAY['super_admin'::text]) OR (has_any_role(ARRAY['admin'::text]) AND (is_global = false) AND (restaurant_id = get_user_store_id()))));

CREATE POLICY qc_templates_select ON public.qc_templates
AS PERMISSIVE
FOR SELECT TO public
USING (((is_global = true) OR (restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

CREATE POLICY qc_templates_update ON public.qc_templates
AS PERMISSIVE
FOR UPDATE TO public
USING ((has_any_role(ARRAY['super_admin'::text]) OR (has_any_role(ARRAY['admin'::text]) AND (is_global = false) AND (restaurant_id = get_user_store_id()))));

-- restaurant_settings

DROP POLICY IF EXISTS admin_only ON public.restaurant_settings;

CREATE POLICY admin_only ON public.restaurant_settings
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) AND has_any_role(ARRAY['admin'::text, 'super_admin'::text])))
WITH CHECK (((restaurant_id = get_user_store_id()) AND has_any_role(ARRAY['admin'::text, 'super_admin'::text])));

-- restaurants

DROP POLICY IF EXISTS restaurants_select_policy ON public.restaurants;

CREATE POLICY restaurants_select_policy ON public.restaurants
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (id = get_user_store_id())));

-- staff_wage_configs

DROP POLICY IF EXISTS restaurant_isolation ON public.staff_wage_configs;

CREATE POLICY restaurant_isolation ON public.staff_wage_configs
AS PERMISSIVE
FOR ALL TO public
USING (((restaurant_id = get_user_store_id()) OR has_any_role(ARRAY['super_admin'::text])));

-- tables

DROP POLICY IF EXISTS tables_select_policy ON public.tables;

CREATE POLICY tables_select_policy ON public.tables
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

-- users

DROP POLICY IF EXISTS users_select_policy ON public.users;

CREATE POLICY users_select_policy ON public.users
AS PERMISSIVE
FOR SELECT TO authenticated
USING ((is_super_admin() OR (restaurant_id = get_user_store_id())));

COMMIT;
