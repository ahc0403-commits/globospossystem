-- Customer QR ordering now finishes at submission: print to kitchen/current
-- floor, expose the table to cashier immediately, and keep kitchen UI optional.
-- Also adds explicit KO/VI/EN menu labels and configurable part-timer rules.

ALTER TABLE public.menu_categories
  ADD COLUMN IF NOT EXISTS name_ko text,
  ADD COLUMN IF NOT EXISTS name_vi text,
  ADD COLUMN IF NOT EXISTS name_en text;

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS name_ko text,
  ADD COLUMN IF NOT EXISTS name_vi text,
  ADD COLUMN IF NOT EXISTS name_en text;

UPDATE public.menu_categories
SET name_ko = COALESCE(NULLIF(btrim(name_ko), ''), name),
    name_vi = COALESCE(NULLIF(btrim(name_vi), ''), name),
    name_en = COALESCE(NULLIF(btrim(name_en), ''), name)
WHERE name_ko IS NULL OR name_vi IS NULL OR name_en IS NULL;

UPDATE public.menu_items
SET name_ko = COALESCE(NULLIF(btrim(name_ko), ''), name),
    name_vi = COALESCE(NULLIF(btrim(name_vi), ''), name),
    name_en = COALESCE(NULLIF(btrim(name_en), ''), name)
WHERE name_ko IS NULL OR name_vi IS NULL OR name_en IS NULL;

CREATE OR REPLACE FUNCTION public.admin_create_menu_category_i18n(
  p_store_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_sort_order integer DEFAULT 0
) RETURNS public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_created public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;

  INSERT INTO public.menu_categories(
    restaurant_id, name, name_ko, name_vi, name_en,
    sort_order, is_active, created_at
  ) VALUES (
    p_store_id, btrim(p_name_ko), btrim(p_name_ko), btrim(p_name_vi),
    btrim(p_name_en), COALESCE(p_sort_order, 0), true, now()
  ) RETURNING * INTO v_created;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_create_menu_category', 'menu_categories', v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'new_values', jsonb_build_object(
        'name_ko', v_created.name_ko,
        'name_vi', v_created.name_vi,
        'name_en', v_created.name_en
      )
    )
  );
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_menu_category_i18n(
  p_category_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text
) RETURNS public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
  v_updated public.menu_categories%ROWTYPE;
BEGIN
  SELECT * INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;

  UPDATE public.menu_categories
  SET name = btrim(p_name_ko),
      name_ko = btrim(p_name_ko),
      name_vi = btrim(p_name_vi),
      name_en = btrim(p_name_en)
  WHERE id = p_category_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_update_menu_category', 'menu_categories', v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.restaurant_id,
      'old_values', jsonb_build_object(
        'name_ko', v_existing.name_ko,
        'name_vi', v_existing.name_vi,
        'name_en', v_existing.name_en
      ),
      'new_values', jsonb_build_object(
        'name_ko', v_updated.name_ko,
        'name_vi', v_updated.name_vi,
        'name_en', v_updated.name_en
      )
    )
  );
  RETURN v_updated;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_menu_item_i18n(
  p_store_id uuid,
  p_category_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_price numeric,
  p_sort_order integer DEFAULT 0,
  p_is_available boolean DEFAULT true
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE id = p_category_id AND restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items(
    restaurant_id, category_id, name, name_ko, name_vi, name_en,
    price, is_available, is_visible_public, sort_order, created_at, updated_at
  ) VALUES (
    p_store_id, p_category_id, btrim(p_name_ko), btrim(p_name_ko),
    btrim(p_name_vi), btrim(p_name_en), p_price,
    COALESCE(p_is_available, true), false, COALESCE(p_sort_order, 0), now(), now()
  ) RETURNING * INTO v_created;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_create_menu_item', 'menu_items', v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'new_values', jsonb_build_object(
        'name_ko', v_created.name_ko,
        'name_vi', v_created.name_vi,
        'name_en', v_created.name_en,
        'price', v_created.price
      )
    )
  );
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_menu_item_i18n(
  p_item_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_price numeric
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
BEGIN
  SELECT * INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;

  UPDATE public.menu_items
  SET name = btrim(p_name_ko),
      name_ko = btrim(p_name_ko),
      name_vi = btrim(p_name_vi),
      name_en = btrim(p_name_en),
      price = p_price,
      updated_at = now()
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_update_menu_item', 'menu_items', v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.restaurant_id,
      'old_values', jsonb_build_object(
        'name_ko', v_existing.name_ko,
        'name_vi', v_existing.name_vi,
        'name_en', v_existing.name_en,
        'price', v_existing.price
      ),
      'new_values', jsonb_build_object(
        'name_ko', v_updated.name_ko,
        'name_vi', v_updated.name_vi,
        'name_en', v_updated.name_en,
        'price', v_updated.price
      )
    )
  );
  RETURN v_updated;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT q.restaurant_id, q.table_id, t.table_number,
         COALESCE(t.floor_label, '1F') AS floor_label, r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', c.id::text,
    'name', c.name,
    'name_ko', COALESCE(NULLIF(c.name_ko, ''), c.name),
    'name_vi', COALESCE(NULLIF(c.name_vi, ''), c.name),
    'name_en', COALESCE(NULLIF(c.name_en, ''), c.name),
    'sort_order', c.sort_order
  ) ORDER BY c.sort_order, c.name, c.id), '[]'::jsonb)
  INTO v_categories
  FROM public.menu_categories c
  WHERE c.restaurant_id = v_table.restaurant_id
    AND c.is_active = true
    AND EXISTS (
      SELECT 1 FROM public.menu_items mi
      WHERE mi.restaurant_id = c.restaurant_id
        AND mi.category_id = c.id
        AND mi.is_available = true
        AND mi.is_visible_public = true
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', mi.id::text,
    'category_id', mi.category_id::text,
    'name', mi.name,
    'name_ko', COALESCE(NULLIF(mi.name_ko, ''), mi.name),
    'name_vi', COALESCE(NULLIF(mi.name_vi, ''), mi.name),
    'name_en', COALESCE(NULLIF(mi.name_en, ''), mi.name),
    'description', mi.description,
    'price', mi.price,
    'image_url', mi.image_url
  ) ORDER BY COALESCE(mc.sort_order, 0), mi.sort_order, mi.name, mi.id), '[]'::jsonb)
  INTO v_items
  FROM public.menu_items mi
  LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
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

-- QR-submitted food is customer-complete and therefore immediately payable.
CREATE OR REPLACE FUNCTION public.qr_order_item_ready_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = NEW.order_id AND o.order_source = 'qr'
  ) THEN
    NEW.status := 'ready';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qr_order_item_ready_before_insert ON public.order_items;
CREATE TRIGGER qr_order_item_ready_before_insert
BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.qr_order_item_ready_before_insert();

-- The confirmation copy already routes to the table's current-floor printer.
-- Suppress the legacy extra floor copy so QR submission creates exactly two
-- tickets: kitchen + floor confirmation.
CREATE OR REPLACE FUNCTION public.qr_order_skip_duplicate_floor_print()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.copy_type = 'floor' AND EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = NEW.order_id AND o.order_source = 'qr'
  ) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qr_order_skip_duplicate_floor_print ON public.print_jobs;
CREATE TRIGGER qr_order_skip_duplicate_floor_print
BEFORE INSERT ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.qr_order_skip_duplicate_floor_print();

CREATE TABLE IF NOT EXISTS public.employee_hourly_pay_rules (
  employee_id uuid PRIMARY KEY REFERENCES public.store_employees(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  hourly_rate numeric(14,2) NOT NULL CHECK (hourly_rate > 0),
  scheduled_start time NOT NULL DEFAULT '09:00',
  night_start time NOT NULL DEFAULT '22:00',
  night_multiplier numeric(6,3) NOT NULL DEFAULT 1.3 CHECK (night_multiplier >= 1),
  holiday_multiplier numeric(6,3) NOT NULL DEFAULT 3 CHECK (holiday_multiplier >= 3),
  exclude_sunday boolean NOT NULL DEFAULT true,
  late_threshold_minutes integer NOT NULL DEFAULT 60 CHECK (late_threshold_minutes >= 0),
  late_review_hourly_multiplier numeric(6,3) NOT NULL DEFAULT 2
    CHECK (late_review_hourly_multiplier >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS employee_hourly_pay_rules_store_idx
  ON public.employee_hourly_pay_rules(store_id, employee_id);

CREATE OR REPLACE FUNCTION public.clear_hourly_pay_rule_for_non_part_timer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.employment_role <> 'part_timer' THEN
    DELETE FROM public.employee_hourly_pay_rules
    WHERE employee_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS clear_hourly_pay_rule_for_non_part_timer
  ON public.store_employees;
CREATE TRIGGER clear_hourly_pay_rule_for_non_part_timer
AFTER UPDATE OF employment_role ON public.store_employees
FOR EACH ROW
WHEN (NEW.employment_role <> 'part_timer')
EXECUTE FUNCTION public.clear_hourly_pay_rule_for_non_part_timer();

CREATE TABLE IF NOT EXISTS public.vietnam_public_holidays (
  holiday_date date PRIMARY KEY,
  name_vi text NOT NULL,
  name_en text NOT NULL,
  source_url text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 2026 dates use the Government's recommended private-employer selection:
-- one pre-Tet + four post-Tet days and 1 September beside National Day.
INSERT INTO public.vietnam_public_holidays(
  holiday_date, name_vi, name_en, source_url
) VALUES
  ('2026-01-01', 'Tết Dương lịch', 'New Year''s Day', 'https://congbao.chinhphu.vn/van-ban/van-ban-hop-nhat-so-18-vbhn-vpqh-468971/62878.htm'),
  ('2026-02-16', 'Tết Âm lịch', 'Lunar New Year', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-02-17', 'Tết Âm lịch', 'Lunar New Year', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-02-18', 'Tết Âm lịch', 'Lunar New Year', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-02-19', 'Tết Âm lịch', 'Lunar New Year', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-02-20', 'Tết Âm lịch', 'Lunar New Year', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-04-26', 'Giỗ Tổ Hùng Vương', 'Hung Kings Commemoration Day', 'https://htpldn.moj.gov.vn/Pages/chi-tiet-thong-bao.aspx?ItemID=120'),
  ('2026-04-30', 'Ngày Chiến thắng', 'Reunification Day', 'https://congbao.chinhphu.vn/van-ban/van-ban-hop-nhat-so-18-vbhn-vpqh-468971/62878.htm'),
  ('2026-05-01', 'Ngày Quốc tế Lao động', 'International Workers'' Day', 'https://congbao.chinhphu.vn/van-ban/van-ban-hop-nhat-so-18-vbhn-vpqh-468971/62878.htm'),
  ('2026-09-01', 'Nghỉ liền kề Quốc khánh', 'National Day adjacent holiday', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm'),
  ('2026-09-02', 'Quốc khánh', 'National Day', 'https://xaydungchinhsach.chinhphu.vn/de-xuat-phuong-an-nghi-tet-am-lich-nghi-le-quoc-khanh-nam-2026-119251002130522291.htm')
ON CONFLICT (holiday_date) DO UPDATE SET
  name_vi = EXCLUDED.name_vi,
  name_en = EXCLUDED.name_en,
  source_url = EXCLUDED.source_url,
  is_active = true;

ALTER TABLE public.employee_hourly_pay_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vietnam_public_holidays ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_hourly_pay_rules_manager_read
  ON public.employee_hourly_pay_rules;
CREATE POLICY employee_hourly_pay_rules_manager_read
ON public.employee_hourly_pay_rules
FOR SELECT TO authenticated
USING (public.workforce_can_manage_store(store_id));

DROP POLICY IF EXISTS vietnam_public_holidays_authenticated_read
  ON public.vietnam_public_holidays;
CREATE POLICY vietnam_public_holidays_authenticated_read
ON public.vietnam_public_holidays
FOR SELECT TO authenticated
USING (true);

REVOKE ALL ON TABLE public.employee_hourly_pay_rules,
  public.vietnam_public_holidays FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.employee_hourly_pay_rules,
  public.vietnam_public_holidays TO authenticated;

CREATE OR REPLACE FUNCTION public.upsert_employee_hourly_pay_rule(
  p_store_id uuid,
  p_employee_id uuid,
  p_hourly_rate numeric,
  p_scheduled_start time DEFAULT '09:00',
  p_night_start time DEFAULT '22:00',
  p_night_multiplier numeric DEFAULT 1.3,
  p_holiday_multiplier numeric DEFAULT 3,
  p_exclude_sunday boolean DEFAULT true,
  p_late_threshold_minutes integer DEFAULT 60,
  p_late_review_hourly_multiplier numeric DEFAULT 2
) RETURNS public.employee_hourly_pay_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_rule public.employee_hourly_pay_rules%ROWTYPE;
BEGIN
  PERFORM public.require_workforce_manager(p_store_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.store_employees
    WHERE id = p_employee_id AND store_id = p_store_id
      AND employment_role = 'part_timer'
  ) THEN
    RAISE EXCEPTION 'PART_TIMER_NOT_FOUND';
  END IF;
  IF p_hourly_rate IS NULL OR p_hourly_rate <= 0
     OR p_night_multiplier < 1 OR p_holiday_multiplier < 3
     OR p_late_threshold_minutes < 0
     OR p_late_review_hourly_multiplier < 0 THEN
    RAISE EXCEPTION 'HOURLY_PAY_RULE_INVALID';
  END IF;

  INSERT INTO public.employee_hourly_pay_rules(
    employee_id, store_id, hourly_rate, scheduled_start, night_start,
    night_multiplier, holiday_multiplier, exclude_sunday,
    late_threshold_minutes, late_review_hourly_multiplier
  ) VALUES (
    p_employee_id, p_store_id, p_hourly_rate, p_scheduled_start, p_night_start,
    p_night_multiplier, p_holiday_multiplier, COALESCE(p_exclude_sunday, true),
    p_late_threshold_minutes, p_late_review_hourly_multiplier
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    store_id = EXCLUDED.store_id,
    hourly_rate = EXCLUDED.hourly_rate,
    scheduled_start = EXCLUDED.scheduled_start,
    night_start = EXCLUDED.night_start,
    night_multiplier = EXCLUDED.night_multiplier,
    holiday_multiplier = EXCLUDED.holiday_multiplier,
    exclude_sunday = EXCLUDED.exclude_sunday,
    late_threshold_minutes = EXCLUDED.late_threshold_minutes,
    late_review_hourly_multiplier = EXCLUDED.late_review_hourly_multiplier,
    updated_at = now()
  RETURNING * INTO v_rule;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'upsert_employee_hourly_pay_rule',
    'employee_hourly_pay_rules', p_employee_id,
    jsonb_build_object('store_id', p_store_id, 'rule', to_jsonb(v_rule))
  );
  RETURN v_rule;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_store_part_timer_with_pay_rule(
  p_store_id uuid,
  p_full_name text,
  p_phone text,
  p_bank_name text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_hourly_rate numeric,
  p_scheduled_start time DEFAULT '09:00',
  p_night_start time DEFAULT '22:00',
  p_night_multiplier numeric DEFAULT 1.3,
  p_holiday_multiplier numeric DEFAULT 3,
  p_late_threshold_minutes integer DEFAULT 60,
  p_late_review_hourly_multiplier numeric DEFAULT 2
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  v_employee := public.create_store_employee(
    p_store_id,
    p_full_name,
    'part_timer',
    p_phone,
    p_bank_account_number,
    p_bank_account_holder,
    p_bank_name
  );
  PERFORM public.upsert_employee_hourly_pay_rule(
    p_store_id,
    v_employee.id,
    p_hourly_rate,
    p_scheduled_start,
    p_night_start,
    p_night_multiplier,
    p_holiday_multiplier,
    true,
    p_late_threshold_minutes,
    p_late_review_hourly_multiplier
  );
  RETURN v_employee;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_menu_category_i18n(uuid, text, text, text, integer)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_menu_category_i18n(uuid, text, text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_i18n(uuid, uuid, text, text, text, numeric, integer, boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_i18n(uuid, text, text, text, numeric)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.upsert_employee_hourly_pay_rule(uuid, uuid, numeric, time, time, numeric, numeric, boolean, integer, numeric)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_store_part_timer_with_pay_rule(uuid, text, text, text, text, text, numeric, time, time, numeric, numeric, integer, numeric)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_create_menu_category_i18n(uuid, text, text, text, integer)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_category_i18n(uuid, text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_i18n(uuid, uuid, text, text, text, numeric, integer, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_item_i18n(uuid, text, text, text, numeric)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_employee_hourly_pay_rule(uuid, uuid, numeric, time, time, numeric, numeric, boolean, integer, numeric)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_store_part_timer_with_pay_rule(uuid, text, text, text, text, text, numeric, time, time, numeric, numeric, integer, numeric)
  TO authenticated;

REVOKE ALL ON FUNCTION public.qr_order_item_ready_before_insert()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_order_skip_duplicate_floor_print()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clear_hourly_pay_rule_for_non_part_timer()
  FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.vietnam_public_holidays IS
  'Confirmed Vietnam statutory holiday calendar used by payroll. Update annually from official Government notices.';
