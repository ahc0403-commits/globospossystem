BEGIN;
SET LOCAL lock_timeout = '3s';

-- An actual allocation change updates its parent discount exactly once, so the
-- existing orders-domain trigger invalidates connected cashiers. Unchanged reads
-- remain write-free. Payment amounts, allocation arithmetic and RPC grants stay intact.
CREATE OR REPLACE FUNCTION public.sync_active_order_promotion(
  p_order_id uuid,
  p_store_id uuid,
  p_at timestamptz DEFAULT now()
) RETURNS public.order_discounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_promo public.store_promotions%ROWTYPE;
  v_existing public.order_discounts%ROWTYPE;
  v_vat_pricing_mode text := 'exclusive';
  v_total numeric(15,2) := 0;
  v_amount numeric(15,2) := 0;
  v_result public.order_discounts%ROWTYPE;
  v_desired_lines jsonb;
  v_existing_lines jsonb;
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id;

  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled')
     OR COALESCE(v_order.order_purpose, 'customer') <> 'customer' THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_existing
  FROM public.order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  -- Manager-approved manual/coupon discounts are never silently destroyed.
  -- The cashier now exposes their source and provides an explicit void action.
  IF FOUND AND v_existing.approved_via <> 'scheduled_promotion' THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_promo
  FROM public.store_promotions promotion
  WHERE promotion.restaurant_id = p_store_id
    AND promotion.is_active = true
    AND promotion.starts_at <= p_at
    AND promotion.ends_at > p_at
    AND (
      promotion.channel = 'both'
      OR promotion.channel = CASE
        WHEN v_order.order_source = 'qr' THEN 'qr'
        ELSE 'pos'
      END
    )
  ORDER BY promotion.starts_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    IF v_existing.id IS NOT NULL THEN
      UPDATE public.order_discounts
      SET status = 'voided',
          void_reason = 'promotion_inactive',
          updated_at = now()
      WHERE id = v_existing.id;
    END IF;
    RETURN NULL;
  END IF;

  SELECT COALESCE(restaurant.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id;

  SELECT ROUND(COALESCE(sum(
    CASE
      WHEN v_vat_pricing_mode = 'inclusive'
        THEN ROUND(item.unit_price * item.quantity, 2)
      ELSE
        ROUND(item.unit_price * item.quantity, 2)
        + ROUND(
            ROUND(item.unit_price * item.quantity, 2)
            * CASE COALESCE(menu.vat_category, 'food')
                WHEN 'alcohol' THEN 10 ELSE 8 END / 100,
            2
          )
    END
  ), 0), 2)
  INTO v_total
  FROM public.order_items item
  LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
  WHERE item.order_id = p_order_id
    AND item.restaurant_id = p_store_id
    AND item.status <> 'cancelled'
    AND item.item_type = 'menu_item'
    AND COALESCE(item.is_service_item, false) = false
    AND (
      v_promo.scope = 'all_menu'
      OR EXISTS (
        SELECT 1
        FROM public.store_promotion_menu_items target
        WHERE target.promotion_id = v_promo.id
          AND target.restaurant_id = p_store_id
          AND target.menu_item_id = item.menu_item_id
      )
    );

  v_amount := ROUND(v_total * v_promo.discount_percent / 100, 0);
  IF v_total <= 0 OR v_amount <= 0 THEN
    IF v_existing.id IS NOT NULL THEN
      UPDATE public.order_discounts
      SET status = 'voided',
          void_reason = 'promotion_total_empty',
          updated_at = now()
      WHERE id = v_existing.id;
    END IF;
    RETURN NULL;
  END IF;

  WITH eligible AS (
    SELECT
      item.id AS order_item_id,
      item.menu_item_id,
      CASE
        WHEN v_vat_pricing_mode = 'inclusive'
          THEN ROUND(item.unit_price * item.quantity, 2)
        ELSE
          ROUND(item.unit_price * item.quantity, 2)
          + ROUND(
              ROUND(item.unit_price * item.quantity, 2)
              * CASE COALESCE(menu.vat_category, 'food')
                  WHEN 'alcohol' THEN 10 ELSE 8 END / 100,
              2
            )
      END AS line_amount
    FROM public.order_items item
    LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
    WHERE item.order_id = p_order_id
      AND item.restaurant_id = p_store_id
      AND item.status <> 'cancelled'
      AND item.item_type = 'menu_item'
      AND COALESCE(item.is_service_item, false) = false
      AND (
        v_promo.scope = 'all_menu'
        OR EXISTS (
          SELECT 1
          FROM public.store_promotion_menu_items target
          WHERE target.promotion_id = v_promo.id
            AND target.restaurant_id = p_store_id
            AND target.menu_item_id = item.menu_item_id
        )
      )
  ), raw_allocations AS (
    SELECT
      eligible.*,
      FLOOR(v_amount * eligible.line_amount / v_total) AS base_amount,
      (v_amount * eligible.line_amount / v_total)
        - FLOOR(v_amount * eligible.line_amount / v_total) AS fraction
    FROM eligible
  ), ranked AS (
    SELECT
      raw_allocations.*,
      row_number() OVER (
        ORDER BY fraction DESC, order_item_id
      ) AS allocation_rank,
      sum(base_amount) OVER () AS allocated_base_total
    FROM raw_allocations
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_item_id', ranked.order_item_id,
    'menu_item_id', ranked.menu_item_id,
    'restaurant_id', p_store_id,
    'promotion_id', v_promo.id,
    'line_amount_before_discount', ranked.line_amount,
    'discount_percent', v_promo.discount_percent,
    'discount_amount',
    ranked.base_amount
      + CASE
          WHEN ranked.allocation_rank <=
            GREATEST(ROUND(v_amount - ranked.allocated_base_total), 0)::bigint
            THEN 1
          ELSE 0
        END
  ) ORDER BY ranked.order_item_id), '[]'::jsonb)
  INTO v_desired_lines
  FROM ranked;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_item_id', allocation.order_item_id,
    'menu_item_id', allocation.menu_item_id,
    'restaurant_id', allocation.restaurant_id,
    'promotion_id', allocation.promotion_id,
    'line_amount_before_discount', allocation.line_amount_before_discount,
    'discount_percent', allocation.discount_percent,
    'discount_amount', allocation.discount_amount
  ) ORDER BY allocation.order_item_id), '[]'::jsonb)
  INTO v_existing_lines
  FROM public.order_discount_lines allocation
  WHERE allocation.order_discount_id = v_existing.id;

  -- Compare the complete persisted contract, not just the order total. Equal
  -- totals can hide a different eligible menu, quantity, or rounding allocation.
  -- The existing active-discount row lock serializes concurrent refreshes.
  IF v_existing.id IS NOT NULL
     AND ROW(v_existing.discount_type, v_existing.discount_mode,
       v_existing.discount_value, v_existing.discount_amount,
       v_existing.reason, v_existing.coupon_code,
       v_existing.proof_storage_path, v_existing.applied_by,
       v_existing.approved_via)
       IS NOT DISTINCT FROM ROW('promotion'::text, 'percent'::text,
         v_promo.discount_percent, v_amount, v_promo.name,
         v_promo.id::text, 'system/promotion/' || v_promo.id::text,
         v_promo.created_by, 'scheduled_promotion'::text)
     AND v_existing_lines IS NOT DISTINCT FROM v_desired_lines THEN
    RETURN v_existing;
  END IF;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.order_discounts
    SET discount_type = 'promotion',
        discount_mode = 'percent',
        discount_value = v_promo.discount_percent,
        discount_amount = v_amount,
        reason = v_promo.name,
        coupon_code = v_promo.id::text,
        proof_storage_path = 'system/promotion/' || v_promo.id::text,
        applied_by = v_promo.created_by,
        approved_via = 'scheduled_promotion',
        updated_at = now()
    -- Line-only changes must also publish the existing parent-row event.
    WHERE id = v_existing.id
      AND (ROW(discount_type, discount_mode, discount_value, discount_amount,
        reason, coupon_code, proof_storage_path, applied_by, approved_via)
        IS DISTINCT FROM ROW('promotion'::text, 'percent'::text,
          v_promo.discount_percent, v_amount, v_promo.name,
          v_promo.id::text, 'system/promotion/' || v_promo.id::text,
          v_promo.created_by, 'scheduled_promotion'::text)
          OR v_existing_lines IS DISTINCT FROM v_desired_lines
        )
    RETURNING * INTO v_result;
    IF NOT FOUND THEN
      v_result := v_existing;
    END IF;
  ELSE
    INSERT INTO public.order_discounts (
      restaurant_id,
      order_id,
      discount_type,
      discount_mode,
      discount_value,
      discount_amount,
      reason,
      coupon_code,
      proof_storage_path,
      applied_by,
      approved_via,
      status
    ) VALUES (
      p_store_id,
      p_order_id,
      'promotion',
      'percent',
      v_promo.discount_percent,
      v_amount,
      v_promo.name,
      v_promo.id::text,
      'system/promotion/' || v_promo.id::text,
      v_promo.created_by,
      'scheduled_promotion',
      'active'
    ) RETURNING * INTO v_result;
  END IF;

  -- Header-only edits preserve line IDs and creation timestamps.
  IF v_existing_lines IS DISTINCT FROM v_desired_lines THEN
    DELETE FROM public.order_discount_lines allocation
    WHERE allocation.order_discount_id = v_result.id;

    INSERT INTO public.order_discount_lines (
      order_discount_id, restaurant_id, order_item_id, menu_item_id,
      promotion_id, line_amount_before_discount, discount_percent, discount_amount
    )
    SELECT v_result.id, line.restaurant_id, line.order_item_id, line.menu_item_id,
      line.promotion_id, line.line_amount_before_discount,
      line.discount_percent, line.discount_amount
    FROM jsonb_to_recordset(v_desired_lines) AS line(
      restaurant_id uuid, order_item_id uuid, menu_item_id uuid,
      promotion_id uuid, line_amount_before_discount numeric,
      discount_percent numeric, discount_amount numeric
    );
  END IF;

  IF (
    SELECT ROUND(COALESCE(sum(allocation.discount_amount), 0), 2)
    FROM public.order_discount_lines allocation
    WHERE allocation.order_discount_id = v_result.id
  ) IS DISTINCT FROM v_amount THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_active_order_promotion(
  uuid, uuid, timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_active_order_promotion(
  uuid, uuid, timestamptz
) TO service_role;

COMMIT;
