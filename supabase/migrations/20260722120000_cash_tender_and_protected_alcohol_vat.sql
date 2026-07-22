-- Cash tender/change receipts and a protected canonical alcohol VAT category.

ALTER TABLE public.menu_categories
  ADD COLUMN IF NOT EXISTS system_key text;

ALTER TABLE public.menu_categories
  DROP CONSTRAINT IF EXISTS menu_categories_system_key_check;
ALTER TABLE public.menu_categories
  ADD CONSTRAINT menu_categories_system_key_check
  CHECK (system_key IS NULL OR system_key = 'alcohol');

CREATE UNIQUE INDEX IF NOT EXISTS menu_categories_restaurant_system_key_uidx
  ON public.menu_categories(restaurant_id, system_key)
  WHERE system_key IS NOT NULL;

-- Existing menu-bearing stores receive one fixed category. If a Korean alcohol
-- category already exists, promote it instead of creating a duplicate.
UPDATE public.menu_categories mc
SET name = '주류',
    name_ko = '주류',
    name_vi = 'Đồ uống có cồn',
    name_en = 'Alcohol',
    system_key = 'alcohol',
    is_active = true
WHERE mc.system_key IS NULL
  AND lower(btrim(COALESCE(mc.name_ko, mc.name))) IN ('주류', 'alcohol')
  AND mc.id = (
    SELECT candidate.id
    FROM public.menu_categories candidate
    WHERE candidate.restaurant_id = mc.restaurant_id
      AND candidate.system_key IS NULL
      AND lower(btrim(COALESCE(candidate.name_ko, candidate.name)))
        IN ('주류', 'alcohol')
    ORDER BY candidate.created_at, candidate.id
    LIMIT 1
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.menu_categories existing
    WHERE existing.restaurant_id = mc.restaurant_id
      AND existing.system_key = 'alcohol'
  );

WITH candidates AS (
  SELECT DISTINCT mc.restaurant_id
  FROM public.menu_categories mc
)
INSERT INTO public.menu_categories(
  restaurant_id, name, name_ko, name_vi, name_en,
  sort_order, is_active, system_key, created_at
)
SELECT
  c.restaurant_id,
  '주류',
  '주류',
  'Đồ uống có cồn',
  'Alcohol',
  COALESCE((
    SELECT max(existing.sort_order) + 1
    FROM public.menu_categories existing
    WHERE existing.restaurant_id = c.restaurant_id
  ), 0),
  true,
  'alcohol',
  now()
FROM candidates c
WHERE NOT EXISTS (
  SELECT 1 FROM public.menu_categories existing
  WHERE existing.restaurant_id = c.restaurant_id
    AND existing.system_key = 'alcohol'
);

CREATE OR REPLACE FUNCTION public.protect_system_menu_category()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.system_key = 'alcohol' THEN
    RAISE EXCEPTION 'MENU_SYSTEM_CATEGORY_PROTECTED';
  END IF;

  IF TG_OP <> 'DELETE' AND NEW.system_key = 'alcohol' THEN
    IF NEW.name IS DISTINCT FROM '주류'
       OR NEW.name_ko IS DISTINCT FROM '주류'
       OR NEW.name_vi IS DISTINCT FROM 'Đồ uống có cồn'
       OR NEW.name_en IS DISTINCT FROM 'Alcohol'
       OR NEW.is_active IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'MENU_ALCOHOL_CATEGORY_NAME_FIXED';
    END IF;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.system_key = 'alcohol'
     AND NEW.system_key IS DISTINCT FROM 'alcohol' THEN
    RAISE EXCEPTION 'MENU_SYSTEM_CATEGORY_PROTECTED';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_system_menu_category_trigger
  ON public.menu_categories;
CREATE TRIGGER protect_system_menu_category_trigger
BEFORE INSERT OR UPDATE OR DELETE ON public.menu_categories
FOR EACH ROW EXECUTE FUNCTION public.protect_system_menu_category();

CREATE OR REPLACE FUNCTION public.ensure_default_alcohol_category()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.system_key IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.menu_categories mc
    WHERE mc.restaurant_id = NEW.restaurant_id
      AND mc.system_key = 'alcohol'
  ) THEN
    INSERT INTO public.menu_categories(
      restaurant_id, name, name_ko, name_vi, name_en,
      sort_order, is_active, system_key, created_at
    ) VALUES (
      NEW.restaurant_id, '주류', '주류', 'Đồ uống có cồn', 'Alcohol',
      NEW.sort_order + 1, true, 'alcohol', now()
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ensure_default_alcohol_category_trigger
  ON public.menu_categories;
CREATE TRIGGER ensure_default_alcohol_category_trigger
AFTER INSERT ON public.menu_categories
FOR EACH ROW EXECUTE FUNCTION public.ensure_default_alcohol_category();

CREATE OR REPLACE FUNCTION public.sync_menu_item_vat_category()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_system_key text;
BEGIN
  SELECT mc.system_key
  INTO v_system_key
  FROM public.menu_categories mc
  WHERE mc.id = NEW.category_id
    AND mc.restaurant_id = NEW.restaurant_id;

  NEW.vat_category := CASE
    WHEN v_system_key = 'alcohol' THEN 'alcohol'
    ELSE 'food'
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_menu_item_vat_category_trigger
  ON public.menu_items;
CREATE TRIGGER sync_menu_item_vat_category_trigger
BEFORE INSERT OR UPDATE OF category_id, restaurant_id, vat_category
ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.sync_menu_item_vat_category();

UPDATE public.menu_items mi
SET vat_category = CASE
  WHEN mc.system_key = 'alcohol' THEN 'alcohol'
  ELSE 'food'
END
FROM public.menu_categories mc
WHERE mc.id = mi.category_id
  AND mi.vat_category IS DISTINCT FROM CASE
    WHEN mc.system_key = 'alcohol' THEN 'alcohol'
    ELSE 'food'
  END;

UPDATE public.menu_items
SET vat_category = 'food'
WHERE category_id IS NULL
  AND vat_category IS DISTINCT FROM 'food';

-- Menu prices are pretax: regular menu items add 8%, protected alcohol adds 10%.
UPDATE public.restaurants r
SET vat_pricing_mode = 'exclusive'
WHERE EXISTS (
  SELECT 1 FROM public.menu_categories mc WHERE mc.restaurant_id = r.id
)
AND r.vat_pricing_mode IS DISTINCT FROM 'exclusive';

-- Preserve explicit cash tender values while retaining legacy total/zero defaults.
CREATE OR REPLACE FUNCTION public.enrich_cashier_receipt_payload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_profile record;
  v_discount numeric(15,2) := 0;
  v_subtotal numeric(15,2) := 0;
  v_cashier text := 'CASHIER';
  v_receipt_no text;
  v_order_no text;
  v_address_lines jsonb := '[]'::jsonb;
BEGIN
  IF NEW.copy_type <> 'receipt' OR NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT
    CASE WHEN lower(COALESCE(b.name, r.name)) LIKE '%bunsik%'
      THEN 'BUNSIK CLUB' ELSE COALESCE(b.name, r.name) END AS brand_name,
    CASE WHEN lower(COALESCE(b.name, r.name)) LIKE '%bunsik%'
      THEN 'CÔNG TY TNHH AKJ INTERNATIONAL' ELSE te.name END AS legal_name,
    CASE WHEN lower(COALESCE(b.name, r.name)) LIKE '%bunsik%'
      THEN '0318453298' ELSE NULLIF(te.tax_code, 'PLACEHOLDER_DEV_000') END AS tax_code,
    r.address
  INTO v_profile
  FROM public.orders o
  JOIN public.restaurants r ON r.id = o.restaurant_id
  LEFT JOIN public.brands b ON b.id = r.brand_id
  LEFT JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE o.id = NEW.order_id;

  IF lower(COALESCE(v_profile.brand_name, '')) LIKE '%bunsik%' THEN
    v_address_lines := jsonb_build_array(
      '69/1A2 Nguyễn Gia Trí',
      'Phường Thạnh Mỹ Tây',
      'Thành phố Hồ Chí Minh'
    );
  ELSIF NULLIF(v_profile.address, '') IS NOT NULL THEN
    v_address_lines := jsonb_build_array(v_profile.address);
  END IF;

  SELECT ROUND(COALESCE(SUM(oi.unit_price * oi.quantity), 0), 2)
  INTO v_subtotal
  FROM public.order_items oi
  WHERE oi.order_id = NEW.order_id
    AND oi.status <> 'cancelled'
    AND NOT COALESCE(oi.is_service_item, false);

  SELECT ROUND(COALESCE(SUM(od.discount_amount), 0), 2)
  INTO v_discount
  FROM public.order_discounts od
  WHERE od.order_id = NEW.order_id
    AND od.status IN ('active', 'consumed');

  SELECT COALESCE(NULLIF(u.fixed_account_code, ''), NULLIF(u.full_name, ''), 'CASHIER')
  INTO v_cashier
  FROM public.payments p
  LEFT JOIN public.users u ON u.auth_id = p.processed_by
  WHERE p.order_id = NEW.order_id
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT 1;

  v_receipt_no := 'BC-' ||
    to_char(COALESCE((NEW.payload->>'at')::timestamptz, now()) AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD') ||
    '-' || lpad((('x' || substr(md5(NEW.order_id::text), 1, 8))::bit(32)::bigint % 1000000)::text, 6, '0');
  v_order_no := lpad((('x' || substr(md5(NEW.order_id::text), 9, 8))::bit(32)::bigint % 100000)::text, 5, '0');

  NEW.payload := NEW.payload || jsonb_build_object(
    'restaurant_name', COALESCE(v_profile.brand_name, NEW.payload->>'restaurant_name'),
    'legal_name', v_profile.legal_name,
    'tax_code', v_profile.tax_code,
    'address_lines', v_address_lines,
    'receipt_number', v_receipt_no,
    'order_number', v_order_no,
    'cashier_code', COALESCE(v_cashier, 'CASHIER'),
    'subtotal_amount', v_subtotal,
    'discount_amount', v_discount,
    'received_amount', COALESCE(
      NULLIF(NEW.payload->>'received_amount', '')::numeric,
      COALESCE((NEW.payload->>'total_amount')::numeric, 0)
    ),
    'change_amount', COALESCE(
      NULLIF(NEW.payload->>'change_amount', '')::numeric,
      0
    )
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_cash_receipt_print_job(
  p_order_id uuid,
  p_received_amount numeric,
  p_reprint boolean DEFAULT false
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_job public.print_jobs%ROWTYPE;
  v_total_amount numeric(15,2);
BEGIN
  IF p_received_amount IS NULL OR p_received_amount <= 0 THEN
    RAISE EXCEPTION 'CASH_RECEIVED_AMOUNT_INVALID';
  END IF;

  SELECT * INTO v_job
  FROM public.enqueue_receipt_print_job(p_order_id, p_reprint);
  v_total_amount := COALESCE((v_job.payload->>'total_amount')::numeric, 0);

  IF p_received_amount < v_total_amount THEN
    RAISE EXCEPTION 'CASH_RECEIVED_AMOUNT_INSUFFICIENT';
  END IF;

  UPDATE public.print_jobs
  SET payload = payload || jsonb_build_object(
    'received_amount', ROUND(p_received_amount, 2),
    'change_amount', ROUND(p_received_amount - v_total_amount, 2)
  )
  WHERE id = v_job.id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_cash_receipt_print_job(uuid, numeric, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_cash_receipt_print_job(uuid, numeric, boolean)
  TO authenticated, service_role;

COMMENT ON COLUMN public.menu_categories.system_key IS
  'Protected system category key. alcohol is fixed to 주류 / Đồ uống có cồn / Alcohol and enforces 10% VAT.';
