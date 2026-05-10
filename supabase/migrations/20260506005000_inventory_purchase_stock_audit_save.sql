-- ============================================================
-- Inventory Purchase Stock Audit Save
-- 2026-05-06
--
-- Mobile stock audit persists counted product quantities and applies the
-- resulting stock adjustment only after the user completes the audit.
-- ============================================================

CREATE OR REPLACE FUNCTION public.save_inventory_stock_audit(
  p_store_id UUID,
  p_lines JSONB,
  p_memo TEXT DEFAULT NULL,
  p_complete BOOLEAN DEFAULT FALSE,
  p_session_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_brand_id UUID;
  v_session_id UUID;
  v_existing_session public.inventory_stock_audit_sessions%ROWTYPE;
  v_line JSONB;
  v_product_id UUID;
  v_actual_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_product public.inventory_products%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_variance_quantity_base NUMERIC(12,3);
  v_variance_amount NUMERIC(12,2);
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN';
  END IF;

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STORE_NOT_FOUND';
  END IF;

  IF p_session_id IS NOT NULL THEN
    SELECT *
    INTO v_existing_session
    FROM public.inventory_stock_audit_sessions
    WHERE id = p_session_id
      AND restaurant_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND';
    END IF;

    IF v_existing_session.status NOT IN ('planned', 'in_progress') THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE';
    END IF;

    UPDATE public.inventory_stock_audit_sessions
    SET status = CASE
          WHEN COALESCE(p_complete, FALSE) THEN 'completed'
          ELSE 'in_progress'
        END,
        started_at = COALESCE(started_at, now()),
        completed_at = CASE
          WHEN COALESCE(p_complete, FALSE) THEN now()
          ELSE NULL
        END,
        memo = COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), memo),
        updated_at = now()
    WHERE id = p_session_id
    RETURNING id INTO v_session_id;

    DELETE FROM public.inventory_stock_audit_lines
    WHERE session_id = v_session_id;
  ELSE
    INSERT INTO public.inventory_stock_audit_sessions (
      restaurant_id,
      brand_id,
      audit_no,
      audit_type,
      status,
      planned_date,
      started_at,
      completed_at,
      created_by,
      assigned_to,
      memo
    )
    VALUES (
      p_store_id,
      v_brand_id,
      'INV-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
      'daily',
      CASE WHEN COALESCE(p_complete, FALSE) THEN 'completed' ELSE 'in_progress' END,
      CURRENT_DATE,
      now(),
      CASE WHEN COALESCE(p_complete, FALSE) THEN now() ELSE NULL END,
      auth.uid(),
      auth.uid(),
      NULLIF(btrim(COALESCE(p_memo, '')), '')
    )
    RETURNING id INTO v_session_id;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_product_id := NULLIF(v_line->>'product_id', '')::UUID;
    v_actual_quantity_base := NULLIF(v_line->>'actual_quantity_base', '')::NUMERIC;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_REQUIRED';
    END IF;

    IF v_actual_quantity_base IS NULL OR v_actual_quantity_base < 0 THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID';
    END IF;

    SELECT *
    INTO v_product
    FROM public.inventory_products
    WHERE id = v_product_id
      AND restaurant_id = p_store_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_NOT_FOUND';
    END IF;

    IF v_product.inventory_item_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_LINKED';
    END IF;

    SELECT *
    INTO v_item
    FROM public.inventory_items
    WHERE id = v_product.inventory_item_id
      AND restaurant_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_FOUND';
    END IF;

    v_variance_quantity_base := v_actual_quantity_base - COALESCE(v_item.current_stock, 0);
    v_variance_amount := ROUND(v_variance_quantity_base * COALESCE(v_item.cost_per_unit, 0), 2);

    INSERT INTO public.inventory_stock_audit_lines (
      session_id,
      product_id,
      theoretical_quantity_base,
      actual_quantity_base,
      variance_quantity_base,
      variance_amount,
      status,
      memo
    )
    VALUES (
      v_session_id,
      v_product_id,
      COALESCE(v_item.current_stock, 0),
      v_actual_quantity_base,
      v_variance_quantity_base,
      v_variance_amount,
      'counted',
      v_line_memo
    );

    IF COALESCE(p_complete, FALSE) THEN
      UPDATE public.inventory_items
      SET current_stock = v_actual_quantity_base,
          quantity = v_actual_quantity_base,
          updated_at = now()
      WHERE id = v_item.id
        AND restaurant_id = p_store_id;

      INSERT INTO public.inventory_transactions (
        restaurant_id,
        ingredient_id,
        transaction_type,
        quantity_g,
        reference_type,
        reference_id,
        note,
        created_by
      )
      VALUES (
        p_store_id,
        v_item.id,
        'adjust',
        v_variance_quantity_base,
        'inventory_stock_audit',
        v_session_id,
        COALESCE(v_line_memo, NULLIF(btrim(COALESCE(p_memo, '')), ''), '실재고 실사'),
        auth.uid()
      );
    END IF;
  END LOOP;

  IF COALESCE(p_complete, FALSE) THEN
    UPDATE public.inventory_stock_audit_sessions
    SET status = 'completed',
        completed_at = now(),
        updated_at = now()
    WHERE id = v_session_id;
  END IF;

  RETURN v_session_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.save_inventory_stock_audit(UUID, JSONB, TEXT, BOOLEAN, UUID) TO authenticated;
