-- ============================================================
-- Inventory Supplier Management RPCs
-- 2026-05-06
--
-- POS-native supplier and supplier-item management for inventory purchase.
-- This remains separate from Office purchase/accounting request domains.
-- ============================================================

CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier(
  p_store_id UUID,
  p_supplier_id UUID DEFAULT NULL,
  p_supplier_name TEXT DEFAULT NULL,
  p_supplier_type TEXT DEFAULT NULL,
  p_contact_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL,
  p_business_registration_no TEXT DEFAULT NULL,
  p_payment_terms TEXT DEFAULT NULL,
  p_contract_start_date DATE DEFAULT NULL,
  p_contract_end_date DATE DEFAULT NULL,
  p_memo TEXT DEFAULT NULL
) RETURNS public.inventory_suppliers AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_supplier_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_NAME_REQUIRED';
  END IF;

  IF p_supplier_id IS NULL THEN
    INSERT INTO public.inventory_suppliers (
      brand_id,
      supplier_name,
      supplier_type,
      contact_name,
      phone,
      email,
      address,
      business_registration_no,
      payment_terms,
      contract_start_date,
      contract_end_date,
      status,
      memo
    ) VALUES (
      v_store.brand_id,
      BTRIM(p_supplier_name),
      NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
      NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
      NULLIF(BTRIM(COALESCE(p_email, '')), ''),
      NULLIF(BTRIM(COALESCE(p_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
      NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
      p_contract_start_date,
      p_contract_end_date,
      'active',
      NULLIF(BTRIM(COALESCE(p_memo, '')), '')
    )
    RETURNING * INTO v_supplier;
  ELSE
    UPDATE public.inventory_suppliers
    SET supplier_name = BTRIM(p_supplier_name),
        supplier_type = NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
        contact_name = NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
        phone = NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
        email = NULLIF(BTRIM(COALESCE(p_email, '')), ''),
        address = NULLIF(BTRIM(COALESCE(p_address, '')), ''),
        business_registration_no = NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
        payment_terms = NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
        contract_start_date = p_contract_start_date,
        contract_end_date = p_contract_end_date,
        memo = NULLIF(BTRIM(COALESCE(p_memo, '')), ''),
        updated_at = now()
    WHERE id = p_supplier_id
      AND (brand_id IS NULL OR brand_id = v_store.brand_id)
    RETURNING * INTO v_supplier;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_supplier;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.set_inventory_supplier_status(
  p_store_id UUID,
  p_supplier_id UUID,
  p_status TEXT
) RETURNS public.inventory_suppliers AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('active', 'inactive', 'suspended') THEN
    RAISE EXCEPTION 'SUPPLIER_STATUS_INVALID';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  UPDATE public.inventory_suppliers
  SET status = p_status,
      updated_at = now()
  WHERE id = p_supplier_id
    AND (brand_id IS NULL OR brand_id = v_store.brand_id)
  RETURNING * INTO v_supplier;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
  END IF;

  RETURN v_supplier;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier_item(
  p_store_id UUID,
  p_supplier_item_id UUID DEFAULT NULL,
  p_supplier_id UUID DEFAULT NULL,
  p_product_id UUID DEFAULT NULL,
  p_supplier_sku TEXT DEFAULT NULL,
  p_order_unit TEXT DEFAULT NULL,
  p_order_unit_quantity_base NUMERIC DEFAULT NULL,
  p_min_order_quantity NUMERIC DEFAULT 1,
  p_unit_price NUMERIC DEFAULT 0,
  p_tax_rate NUMERIC DEFAULT 0,
  p_lead_time_days INT DEFAULT 1,
  p_is_preferred BOOLEAN DEFAULT FALSE
) RETURNS public.inventory_supplier_items AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
  v_product public.inventory_products%ROWTYPE;
  v_item public.inventory_supplier_items%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  SELECT * INTO v_supplier
  FROM public.inventory_suppliers
  WHERE id = p_supplier_id
    AND status = 'active'
    AND (brand_id IS NULL OR brand_id = v_store.brand_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
  END IF;

  SELECT * INTO v_product
  FROM public.inventory_products
  WHERE id = p_product_id
    AND restaurant_id = p_store_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_order_unit, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_UNIT_REQUIRED';
  END IF;

  IF COALESCE(p_order_unit_quantity_base, 0) <= 0 THEN
    RAISE EXCEPTION 'ORDER_UNIT_QUANTITY_INVALID';
  END IF;

  IF COALESCE(p_min_order_quantity, 0) <= 0 THEN
    RAISE EXCEPTION 'MIN_ORDER_QUANTITY_INVALID';
  END IF;

  IF COALESCE(p_unit_price, 0) < 0 THEN
    RAISE EXCEPTION 'UNIT_PRICE_INVALID';
  END IF;

  IF COALESCE(p_tax_rate, 0) < 0 THEN
    RAISE EXCEPTION 'TAX_RATE_INVALID';
  END IF;

  IF COALESCE(p_lead_time_days, 0) < 0 THEN
    RAISE EXCEPTION 'LEAD_TIME_INVALID';
  END IF;

  IF p_is_preferred THEN
    UPDATE public.inventory_supplier_items
    SET is_preferred = FALSE,
        updated_at = now()
    WHERE product_id = p_product_id
      AND supplier_id <> p_supplier_id;
  END IF;

  IF p_supplier_item_id IS NULL THEN
    INSERT INTO public.inventory_supplier_items (
      supplier_id,
      product_id,
      supplier_sku,
      order_unit,
      order_unit_quantity_base,
      min_order_quantity,
      unit_price,
      tax_rate,
      lead_time_days,
      is_preferred,
      is_active
    ) VALUES (
      p_supplier_id,
      p_product_id,
      NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
      BTRIM(p_order_unit),
      p_order_unit_quantity_base,
      p_min_order_quantity,
      p_unit_price,
      COALESCE(p_tax_rate, 0),
      COALESCE(p_lead_time_days, 1),
      COALESCE(p_is_preferred, FALSE),
      TRUE
    )
    ON CONFLICT (supplier_id, product_id, order_unit)
    DO UPDATE SET supplier_sku = EXCLUDED.supplier_sku,
                  order_unit_quantity_base = EXCLUDED.order_unit_quantity_base,
                  min_order_quantity = EXCLUDED.min_order_quantity,
                  unit_price = EXCLUDED.unit_price,
                  tax_rate = EXCLUDED.tax_rate,
                  lead_time_days = EXCLUDED.lead_time_days,
                  is_preferred = EXCLUDED.is_preferred,
                  is_active = TRUE,
                  updated_at = now()
    RETURNING * INTO v_item;
  ELSE
    UPDATE public.inventory_supplier_items
    SET supplier_sku = NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
        order_unit = BTRIM(p_order_unit),
        order_unit_quantity_base = p_order_unit_quantity_base,
        min_order_quantity = p_min_order_quantity,
        unit_price = p_unit_price,
        tax_rate = COALESCE(p_tax_rate, 0),
        lead_time_days = COALESCE(p_lead_time_days, 1),
        is_preferred = COALESCE(p_is_preferred, FALSE),
        is_active = TRUE,
        updated_at = now()
    WHERE id = p_supplier_item_id
      AND supplier_id = p_supplier_id
      AND product_id = p_product_id
    RETURNING * INTO v_item;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_ITEM_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.set_inventory_supplier_item_active(
  p_store_id UUID,
  p_supplier_item_id UUID,
  p_is_active BOOLEAN
) RETURNS public.inventory_supplier_items AS $$
DECLARE
  v_item public.inventory_supplier_items%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN';
  END IF;

  UPDATE public.inventory_supplier_items si
  SET is_active = COALESCE(p_is_active, FALSE),
      updated_at = now()
  FROM public.inventory_products p
  WHERE si.id = p_supplier_item_id
    AND si.product_id = p.id
    AND p.restaurant_id = p_store_id
  RETURNING si.* INTO v_item;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_ITEM_NOT_FOUND';
  END IF;

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.upsert_inventory_supplier(
  UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, TEXT
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_inventory_supplier_status(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_supplier_item(
  UUID, UUID, UUID, UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, INT, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_inventory_supplier_item_active(UUID, UUID, BOOLEAN) TO authenticated;
