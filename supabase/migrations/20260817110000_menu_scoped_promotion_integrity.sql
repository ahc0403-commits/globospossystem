BEGIN;

-- production-gate: self-verifying

-- Keep the existing single-campaign overlap rule, while allowing that campaign
-- to target either every menu or an explicit set of menu items.
ALTER TABLE public.store_promotions
  ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'all_menu';

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.store_promotions'::regclass
      AND conname = 'store_promotions_scope_check'
  ) THEN
    ALTER TABLE public.store_promotions
      ADD CONSTRAINT store_promotions_scope_check
      CHECK (scope IN ('all_menu', 'selected_items'));
  END IF;
END;
$constraint$;

CREATE UNIQUE INDEX IF NOT EXISTS store_promotions_id_restaurant_unique
  ON public.store_promotions (id, restaurant_id);
CREATE UNIQUE INDEX IF NOT EXISTS menu_items_id_restaurant_unique
  ON public.menu_items (id, restaurant_id);

CREATE TABLE IF NOT EXISTS public.store_promotion_menu_items (
  promotion_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  menu_item_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (promotion_id, menu_item_id),
  FOREIGN KEY (promotion_id, restaurant_id)
    REFERENCES public.store_promotions(id, restaurant_id) ON DELETE CASCADE,
  FOREIGN KEY (menu_item_id, restaurant_id)
    REFERENCES public.menu_items(id, restaurant_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS store_promotion_menu_items_store_item
  ON public.store_promotion_menu_items (restaurant_id, menu_item_id);

ALTER TABLE public.store_promotion_menu_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_promotion_menu_items_store_read
  ON public.store_promotion_menu_items;
CREATE POLICY store_promotion_menu_items_store_read
ON public.store_promotion_menu_items
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) store_scope(store_id)
    WHERE store_scope.store_id = store_promotion_menu_items.restaurant_id
  )
);
REVOKE ALL ON public.store_promotion_menu_items
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.store_promotion_menu_items TO authenticated;
GRANT ALL ON public.store_promotion_menu_items TO service_role;

-- Persist the exact allocation used by the cashier and payment transaction.
-- This prevents a selected-menu promotion from being spread over untargeted
-- menu lines and keeps historical menu sales/VAT allocation auditable.
CREATE TABLE IF NOT EXISTS public.order_discount_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_discount_id uuid NOT NULL
    REFERENCES public.order_discounts(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL
    REFERENCES public.order_items(id) ON DELETE CASCADE,
  menu_item_id uuid,
  promotion_id uuid REFERENCES public.store_promotions(id) ON DELETE SET NULL,
  line_amount_before_discount numeric(15,2) NOT NULL
    CHECK (line_amount_before_discount > 0),
  discount_percent numeric(5,2) NOT NULL
    CHECK (discount_percent > 0 AND discount_percent <= 100),
  discount_amount numeric(15,2) NOT NULL
    CHECK (
      discount_amount >= 0
      AND discount_amount <= line_amount_before_discount
    ),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_discount_id, order_item_id)
);

CREATE INDEX IF NOT EXISTS order_discount_lines_order_item
  ON public.order_discount_lines (order_item_id);
CREATE INDEX IF NOT EXISTS order_discount_lines_store
  ON public.order_discount_lines (restaurant_id, order_discount_id);

ALTER TABLE public.order_discount_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS order_discount_lines_store_read
  ON public.order_discount_lines;
CREATE POLICY order_discount_lines_store_read
ON public.order_discount_lines
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) store_scope(store_id)
    WHERE store_scope.store_id = order_discount_lines.restaurant_id
  )
);
REVOKE ALL ON public.order_discount_lines FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_discount_lines TO authenticated;
GRANT ALL ON public.order_discount_lines TO service_role;

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
    WHERE id = v_existing.id
    RETURNING * INTO v_result;
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

  DELETE FROM public.order_discount_lines allocation
  WHERE allocation.order_discount_id = v_result.id;

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
  INSERT INTO public.order_discount_lines (
    order_discount_id,
    restaurant_id,
    order_item_id,
    menu_item_id,
    promotion_id,
    line_amount_before_discount,
    discount_percent,
    discount_amount
  )
  SELECT
    v_result.id,
    p_store_id,
    ranked.order_item_id,
    ranked.menu_item_id,
    v_promo.id,
    ranked.line_amount,
    v_promo.discount_percent,
    ranked.base_amount
      + CASE
          WHEN ranked.allocation_rank <=
            GREATEST(ROUND(v_amount - ranked.allocated_base_total), 0)::bigint
            THEN 1
          ELSE 0
        END
  FROM ranked;

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

CREATE OR REPLACE FUNCTION public.upsert_store_promotion_v2(
  p_store_id uuid,
  p_promotion_id uuid,
  p_name text,
  p_discount_percent numeric,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_scope text DEFAULT 'all_menu',
  p_menu_item_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_is_active boolean DEFAULT true
) RETURNS public.store_promotions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_row public.store_promotions%ROWTYPE;
  v_order_id uuid;
  v_scope text := COALESCE(NULLIF(btrim(p_scope), ''), 'all_menu');
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'PROMOTION_FORBIDDEN'
  );

  IF p_discount_percent IS NULL
     OR p_discount_percent <= 0
     OR p_discount_percent > 100 THEN
    RAISE EXCEPTION 'PROMOTION_PERCENT_INVALID';
  END IF;
  IF p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'PROMOTION_PERIOD_INVALID';
  END IF;
  IF v_scope NOT IN ('all_menu', 'selected_items') THEN
    RAISE EXCEPTION 'PROMOTION_SCOPE_INVALID';
  END IF;
  IF v_scope = 'selected_items'
     AND COALESCE(cardinality(p_menu_item_ids), 0) = 0 THEN
    RAISE EXCEPTION 'PROMOTION_MENU_ITEMS_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(p_menu_item_ids, ARRAY[]::uuid[])) requested(menu_id)
    LEFT JOIN public.menu_items menu
      ON menu.id = requested.menu_id
     AND menu.restaurant_id = p_store_id
     AND COALESCE(menu.is_archived, false) = false
    WHERE menu.id IS NULL
  ) THEN
    RAISE EXCEPTION 'PROMOTION_MENU_ITEM_INVALID';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.store_promotions promotion
    WHERE promotion.restaurant_id = p_store_id
      AND promotion.is_active = true
      AND promotion.id IS DISTINCT FROM p_promotion_id
      AND tstzrange(promotion.starts_at, promotion.ends_at, '[)')
        && tstzrange(p_starts_at, p_ends_at, '[)')
  ) THEN
    RAISE EXCEPTION 'PROMOTION_PERIOD_OVERLAP';
  END IF;

  INSERT INTO public.store_promotions (
    id,
    restaurant_id,
    name,
    discount_percent,
    starts_at,
    ends_at,
    channel,
    scope,
    is_active,
    created_by
  ) VALUES (
    COALESCE(p_promotion_id, gen_random_uuid()),
    p_store_id,
    btrim(p_name),
    ROUND(p_discount_percent, 2),
    p_starts_at,
    p_ends_at,
    'both',
    v_scope,
    COALESCE(p_is_active, true),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    discount_percent = EXCLUDED.discount_percent,
    starts_at = EXCLUDED.starts_at,
    ends_at = EXCLUDED.ends_at,
    channel = EXCLUDED.channel,
    scope = EXCLUDED.scope,
    is_active = EXCLUDED.is_active,
    updated_at = now()
  WHERE public.store_promotions.restaurant_id = p_store_id
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'PROMOTION_FORBIDDEN';
  END IF;

  DELETE FROM public.store_promotion_menu_items target
  WHERE target.promotion_id = v_row.id;

  IF v_scope = 'selected_items' THEN
    INSERT INTO public.store_promotion_menu_items (
      promotion_id,
      restaurant_id,
      menu_item_id
    )
    SELECT v_row.id, p_store_id, requested.menu_id
    FROM (
      SELECT DISTINCT unnest(p_menu_item_ids) AS menu_id
    ) requested;
  END IF;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'upsert_store_promotion',
    'store_promotions',
    v_row.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'name', v_row.name,
      'discount_percent', v_row.discount_percent,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at,
      'scope', v_row.scope,
      'menu_item_count', CASE
        WHEN v_scope = 'selected_items'
          THEN cardinality(ARRAY(SELECT DISTINCT unnest(p_menu_item_ids)))
        ELSE 0
      END,
      'is_active', v_row.is_active
    )
  );

  FOR v_order_id IN
    SELECT orders.id
    FROM public.orders orders
    WHERE orders.restaurant_id = p_store_id
      AND orders.status NOT IN ('completed', 'cancelled')
      AND COALESCE(orders.order_purpose, 'customer') = 'customer'
  LOOP
    PERFORM public.sync_active_order_promotion(
      v_order_id,
      p_store_id,
      now()
    );
  END LOOP;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_store_promotion(
  p_store_id uuid,
  p_promotion_id uuid,
  p_name text,
  p_discount_percent numeric,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_is_active boolean DEFAULT true
) RETURNS public.store_promotions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  RETURN public.upsert_store_promotion_v2(
    p_store_id,
    p_promotion_id,
    p_name,
    p_discount_percent,
    p_starts_at,
    p_ends_at,
    'all_menu',
    ARRAY[]::uuid[],
    p_is_active
  );
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_store_promotion_v2(
  uuid, uuid, text, numeric, timestamptz, timestamptz, text, uuid[], boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_store_promotion_v2(
  uuid, uuid, text, numeric, timestamptz, timestamptz, text, uuid[], boolean
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.upsert_store_promotion(
  uuid, uuid, text, numeric, timestamptz, timestamptz, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_store_promotion(
  uuid, uuid, text, numeric, timestamptz, timestamptz, boolean
) TO authenticated, service_role;

-- Preserve the already-verified payment implementation as the atomic anchor.
-- The new public wrapper only supplies and verifies exact scheduled-promotion
-- allocations, then delegates payment, inventory, and invoice work unchanged.
ALTER FUNCTION public.process_payment(uuid, uuid, numeric, text)
  RENAME TO process_payment_without_scoped_promotions;

REVOKE ALL ON FUNCTION public.process_payment_without_scoped_promotions(
  uuid, uuid, numeric, text
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.process_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_method text
) RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_discount public.order_discounts%ROWTYPE;
  v_original_mode text;
  v_original_value numeric(12,2);
  v_allocation_total numeric(15,2);
  v_has_allocations boolean := false;
  v_vat_pricing_mode text := 'exclusive';
  v_line record;
  v_line_gross numeric(15,2);
  v_line_inc numeric(15,2);
  v_line_after_discount numeric(15,2);
  v_pretax numeric(15,2);
  v_vat_rate numeric(5,2);
  v_vat_amount numeric(15,2);
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT * INTO v_discount
  FROM public.order_discounts discount
  WHERE discount.order_id = p_order_id
    AND discount.restaurant_id = p_store_id
    AND discount.status = 'active'
  FOR UPDATE;

  IF FOUND AND v_discount.approved_via = 'scheduled_promotion' THEN
    SELECT
      count(*) > 0,
      ROUND(COALESCE(sum(allocation.discount_amount), 0), 2)
    INTO v_has_allocations, v_allocation_total
    FROM public.order_discount_lines allocation
    WHERE allocation.order_discount_id = v_discount.id;

    IF v_has_allocations
       AND v_allocation_total IS DISTINCT FROM
         ROUND(v_discount.discount_amount, 2) THEN
      RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
    END IF;
  END IF;

  IF v_has_allocations THEN
    v_original_mode := v_discount.discount_mode;
    v_original_value := v_discount.discount_value;

    UPDATE public.order_discounts
    SET discount_mode = 'amount',
        discount_value = v_allocation_total,
        discount_amount = v_allocation_total,
        updated_at = now()
    WHERE id = v_discount.id;
  END IF;

  v_payment := public.process_payment_without_scoped_promotions(
    p_order_id,
    p_store_id,
    p_amount,
    p_method
  );

  IF NOT v_has_allocations THEN
    RETURN v_payment;
  END IF;

  UPDATE public.order_discounts
  SET discount_mode = v_original_mode,
      discount_value = v_original_value,
      discount_amount = v_allocation_total,
      updated_at = now()
  WHERE id = v_discount.id;

  SELECT COALESCE(restaurant.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id;

  FOR v_line IN
    SELECT
      item.id,
      item.unit_price,
      item.quantity,
      COALESCE(menu.vat_category, 'food') AS vat_category,
      COALESCE(allocation.discount_amount, 0) AS discount_amount
    FROM public.order_items item
    LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
    LEFT JOIN public.order_discount_lines allocation
      ON allocation.order_discount_id = v_discount.id
     AND allocation.order_item_id = item.id
    WHERE item.order_id = p_order_id
      AND item.restaurant_id = p_store_id
      AND item.status <> 'cancelled'
      AND item.item_type = 'menu_item'
      AND COALESCE(item.is_service_item, false) = false
    ORDER BY item.created_at, item.id
  LOOP
    v_line_gross := ROUND(v_line.unit_price * v_line.quantity, 2);
    v_vat_rate := CASE v_line.vat_category
      WHEN 'alcohol' THEN 10 ELSE 8 END;

    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_inc := v_line_gross;
    ELSE
      v_line_inc := v_line_gross
        + ROUND(v_line_gross * v_vat_rate / 100, 2);
    END IF;

    v_line_after_discount := ROUND(
      GREATEST(v_line_inc - v_line.discount_amount, 0),
      2
    );
    v_pretax := ROUND(
      v_line_after_discount / (1 + (v_vat_rate / 100)),
      2
    );
    v_vat_amount := v_line_after_discount - v_pretax;

    UPDATE public.order_items
    SET vat_rate = v_vat_rate,
        vat_amount = v_vat_amount,
        total_amount_ex_tax = v_pretax,
        paying_amount_inc_tax = v_line_after_discount
    WHERE id = v_line.id;
  END LOOP;

  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
  TO authenticated, service_role;

-- Avoid promotion resync when payment only writes VAT/payment snapshot fields.
DROP TRIGGER IF EXISTS trg_sync_order_promotion ON public.order_items;
CREATE TRIGGER trg_sync_order_promotion
AFTER INSERT OR DELETE OR UPDATE OF
  unit_price, quantity, status, menu_item_id, is_service_item
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.trg_sync_order_promotion();

-- Preserve the latest combo/drink QR contract while exposing a discounted
-- price only on menu items targeted by the active campaign.
CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_promotion public.store_promotions%ROWTYPE;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT
    qr.restaurant_id,
    qr.table_id,
    table_row.table_number,
    COALESCE(table_row.floor_label, '1F') AS floor_label,
    restaurant.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id
   AND restaurant.is_active = true
  WHERE qr.token = v_token AND qr.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT * INTO v_promotion
  FROM public.store_promotions promotion
  WHERE promotion.restaurant_id = v_table.restaurant_id
    AND promotion.is_active = true
    AND promotion.starts_at <= now()
    AND promotion.ends_at > now()
    AND promotion.channel IN ('both', 'qr')
  ORDER BY promotion.starts_at DESC
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', category.id::text,
    'name', category.name,
    'name_ko', COALESCE(NULLIF(category.name_ko, ''), category.name),
    'name_vi', COALESCE(NULLIF(category.name_vi, ''), category.name),
    'name_en', COALESCE(NULLIF(category.name_en, ''), category.name),
    'sort_order', category.sort_order
  ) ORDER BY category.sort_order, category.name, category.id), '[]'::jsonb)
  INTO v_categories
  FROM public.menu_categories category
  WHERE category.restaurant_id = v_table.restaurant_id
    AND category.is_active = true
    AND EXISTS (
      SELECT 1
      FROM public.menu_items menu
      WHERE menu.restaurant_id = category.restaurant_id
        AND menu.category_id = category.id
        AND menu.is_available = true
        AND menu.is_visible_public = true
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', menu.id::text,
    'category_id', menu.category_id::text,
    'name', menu.name,
    'name_ko', COALESCE(NULLIF(menu.name_ko, ''), menu.name),
    'name_vi', COALESCE(NULLIF(menu.name_vi, ''), menu.name),
    'name_en', COALESCE(NULLIF(menu.name_en, ''), menu.name),
    'description', menu.description,
    'original_price', menu.price,
    'price', CASE
      WHEN v_promotion.id IS NULL THEN menu.price
      WHEN v_promotion.scope = 'selected_items'
           AND NOT EXISTS (
             SELECT 1
             FROM public.store_promotion_menu_items target
             WHERE target.promotion_id = v_promotion.id
               AND target.restaurant_id = v_table.restaurant_id
               AND target.menu_item_id = menu.id
           ) THEN menu.price
      ELSE ROUND(
        menu.price * (100 - v_promotion.discount_percent) / 100,
        0
      )
    END,
    'discount_percent', CASE
      WHEN v_promotion.id IS NULL THEN 0
      WHEN v_promotion.scope = 'selected_items'
           AND NOT EXISTS (
             SELECT 1
             FROM public.store_promotion_menu_items target
             WHERE target.promotion_id = v_promotion.id
               AND target.restaurant_id = v_table.restaurant_id
               AND target.menu_item_id = menu.id
           ) THEN 0
      ELSE v_promotion.discount_percent
    END,
    'image_url', menu.image_url,
    'is_combo', menu.is_combo,
    'combo_drink_choice_count', CASE
      WHEN menu.is_combo THEN public.combo_drink_choice_count(menu.id)
      ELSE 0
    END,
    'combo_drink_options', CASE
      WHEN menu.is_combo THEN public.combo_drink_options(menu.id)
      ELSE '[]'::jsonb
    END
  ) ORDER BY
      COALESCE(category.sort_order, 0),
      menu.sort_order,
      menu.name,
      menu.id
  ), '[]'::jsonb)
  INTO v_items
  FROM public.menu_items menu
  LEFT JOIN public.menu_categories category ON category.id = menu.category_id
  WHERE menu.restaurant_id = v_table.restaurant_id
    AND menu.is_available = true
    AND menu.is_visible_public = true
    AND (category.id IS NULL OR category.is_active = true);

  RETURN jsonb_build_object(
    'store_id', v_table.restaurant_id::text,
    'store_name', v_table.store_name,
    'table_id', v_table.table_id::text,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'promotion_name', v_promotion.name,
    'promotion_discount_percent', COALESCE(v_promotion.discount_percent, 0),
    'promotion_scope', COALESCE(v_promotion.scope, 'all_menu'),
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

DO $verify$
DECLARE
  v_payment_definition text;
  v_sync_definition text;
BEGIN
  IF to_regclass('public.store_promotion_menu_items') IS NULL
     OR to_regclass('public.order_discount_lines') IS NULL
     OR to_regprocedure(
       'public.upsert_store_promotion_v2(uuid,uuid,text,numeric,timestamp with time zone,timestamp with time zone,text,uuid[],boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SCOPED_PROMOTION_OBJECT_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.process_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_payment_definition;
  SELECT pg_get_functiondef(
    'public.sync_active_order_promotion(uuid,uuid,timestamp with time zone)'::regprocedure
  ) INTO v_sync_definition;

  IF position('PROMOTION_ALLOCATION_MISMATCH' IN v_payment_definition) = 0
     OR position('order_discount_lines' IN v_payment_definition) = 0
     OR position('store_promotion_menu_items' IN v_sync_definition) = 0
     OR has_function_privilege(
       'authenticated',
       'public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.process_payment(uuid,uuid,numeric,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'MENU_SCOPED_PROMOTION_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
