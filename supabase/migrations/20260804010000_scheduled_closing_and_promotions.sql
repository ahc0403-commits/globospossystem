BEGIN;

-- Scheduled closes run without an authenticated operator.
ALTER TABLE public.daily_closings
  ALTER COLUMN closed_by DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS close_source text NOT NULL DEFAULT 'manual'
    CHECK (close_source IN ('manual', 'scheduled')),
  ADD COLUMN IF NOT EXISTS inventory_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(inventory_snapshot) = 'array');

CREATE OR REPLACE FUNCTION public.run_scheduled_daily_closings(
  p_business_date date DEFAULT ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_start timestamptz;
  v_end timestamptz;
  v_count integer := 0;
BEGIN
  v_start := p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end := (p_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  FOR v_store IN SELECT * FROM public.restaurants WHERE is_active = true LOOP
    INSERT INTO public.daily_closings (
      restaurant_id, closing_date, closed_by, close_source,
      orders_total, orders_completed, orders_cancelled, items_cancelled,
      payments_count, payments_total, payments_cash, payments_card,
      payments_pay, service_count, service_total, low_stock_count, notes,
      inventory_snapshot
    )
    SELECT
      v_store.id,
      p_business_date,
      NULL,
      'scheduled',
      (SELECT count(*) FROM public.orders o
       WHERE o.restaurant_id = v_store.id AND o.created_at >= v_start AND o.created_at < v_end),
      (SELECT count(*) FROM public.orders o
       WHERE o.restaurant_id = v_store.id AND o.status = 'completed'
         AND o.created_at >= v_start AND o.created_at < v_end),
      (SELECT count(*) FROM public.orders o
       WHERE o.restaurant_id = v_store.id AND o.status = 'cancelled'
         AND o.created_at >= v_start AND o.created_at < v_end),
      (SELECT count(*) FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
       WHERE o.restaurant_id = v_store.id AND oi.status = 'cancelled'
         AND o.created_at >= v_start AND o.created_at < v_end),
      (SELECT count(*) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = true
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT COALESCE(sum(p.amount), 0) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = true
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT COALESCE(sum(p.amount), 0) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = true AND lower(p.method) = 'cash'
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT COALESCE(sum(p.amount), 0) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = true AND lower(p.method) = 'card'
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT COALESCE(sum(p.amount), 0) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = true
         AND lower(p.method) NOT IN ('cash', 'card')
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT count(*) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = false
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT COALESCE(sum(p.amount), 0) FROM public.payments p
       WHERE p.restaurant_id = v_store.id AND p.is_revenue = false
         AND p.created_at >= v_start AND p.created_at < v_end),
      (SELECT count(*) FROM public.inventory_items i
       WHERE i.restaurant_id = v_store.id AND i.is_active = true
         AND i.reorder_point IS NOT NULL AND i.current_stock <= i.reorder_point),
      'Automatic 23:00 Asia/Ho_Chi_Minh close',
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'item_id', i.id,
          'name', i.name,
          'unit', i.unit,
          'current_stock', COALESCE(i.current_stock, i.quantity, 0),
          'reorder_point', i.reorder_point
        ) ORDER BY i.name, i.id), '[]'::jsonb)
        FROM public.inventory_items i
        WHERE i.restaurant_id = v_store.id AND i.is_active = true)
    ON CONFLICT (restaurant_id, closing_date) DO NOTHING;

    IF FOUND THEN v_count := v_count + 1; END IF;
  END LOOP;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.run_scheduled_daily_closings(date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_scheduled_daily_closings(date)
  TO service_role;

CREATE TABLE IF NOT EXISTS public.store_promotions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  discount_percent numeric(5,2) NOT NULL CHECK (discount_percent > 0 AND discount_percent <= 100),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  channel text NOT NULL DEFAULT 'both' CHECK (channel IN ('both', 'pos', 'qr')),
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);

CREATE INDEX IF NOT EXISTS store_promotions_active_window
  ON public.store_promotions (restaurant_id, starts_at, ends_at)
  WHERE is_active = true;

ALTER TABLE public.store_promotions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_promotions_store_read ON public.store_promotions;
CREATE POLICY store_promotions_store_read ON public.store_promotions
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = store_promotions.restaurant_id
  )
);
REVOKE ALL ON public.store_promotions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.store_promotions TO authenticated;
GRANT ALL ON public.store_promotions TO service_role;

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
DECLARE
  v_row public.store_promotions%ROWTYPE;
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(p_store_id, 'PROMOTION_FORBIDDEN');
  IF p_discount_percent <= 0 OR p_discount_percent > 100 THEN
    RAISE EXCEPTION 'PROMOTION_PERCENT_INVALID';
  END IF;
  IF p_ends_at <= p_starts_at THEN RAISE EXCEPTION 'PROMOTION_PERIOD_INVALID'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.store_promotions p
    WHERE p.restaurant_id = p_store_id AND p.is_active = true
      AND p.id IS DISTINCT FROM p_promotion_id
      AND tstzrange(p.starts_at, p.ends_at, '[)') && tstzrange(p_starts_at, p_ends_at, '[)')
  ) THEN
    RAISE EXCEPTION 'PROMOTION_PERIOD_OVERLAP';
  END IF;

  INSERT INTO public.store_promotions (
    id, restaurant_id, name, discount_percent, starts_at, ends_at,
    channel, is_active, created_by
  ) VALUES (
    COALESCE(p_promotion_id, gen_random_uuid()), p_store_id, btrim(p_name),
    round(p_discount_percent, 2), p_starts_at, p_ends_at, 'both',
    COALESCE(p_is_active, true), auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    discount_percent = EXCLUDED.discount_percent,
    starts_at = EXCLUDED.starts_at,
    ends_at = EXCLUDED.ends_at,
    is_active = EXCLUDED.is_active,
    updated_at = now()
  WHERE public.store_promotions.restaurant_id = p_store_id
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'PROMOTION_FORBIDDEN'; END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'upsert_store_promotion', 'store_promotions', v_row.id,
    jsonb_build_object('store_id', p_store_id, 'name', v_row.name,
      'discount_percent', v_row.discount_percent, 'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at, 'is_active', v_row.is_active));
  RETURN v_row;
END;
$$;

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
  v_total numeric(15,2);
  v_amount numeric(15,2);
  v_result public.order_discounts%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id;
  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled')
     OR COALESCE(v_order.order_purpose, 'customer') <> 'customer' THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_existing FROM public.order_discounts
  WHERE order_id = p_order_id AND status = 'active' FOR UPDATE;
  IF FOUND AND v_existing.approved_via <> 'scheduled_promotion' THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_promo FROM public.store_promotions p
  WHERE p.restaurant_id = p_store_id AND p.is_active = true
    AND p.starts_at <= p_at AND p.ends_at > p_at
    AND (p.channel = 'both' OR p.channel = CASE WHEN v_order.order_source = 'qr' THEN 'qr' ELSE 'pos' END)
  ORDER BY p.starts_at DESC LIMIT 1;

  IF NOT FOUND THEN
    IF v_existing.id IS NOT NULL THEN
      UPDATE public.order_discounts SET status = 'voided', void_reason = 'promotion_inactive', updated_at = now()
      WHERE id = v_existing.id;
    END IF;
    RETURN NULL;
  END IF;

  v_total := public.calculate_order_discountable_total(p_order_id, p_store_id);
  IF v_total <= 0 THEN
    IF v_existing.id IS NOT NULL THEN
      UPDATE public.order_discounts
      SET status = 'voided', void_reason = 'promotion_total_empty', updated_at = now()
      WHERE id = v_existing.id;
    END IF;
    RETURN NULL;
  END IF;
  -- VND is stored and charged as a whole-number currency.
  v_amount := round(v_total * v_promo.discount_percent / 100, 0);

  IF v_existing.id IS NOT NULL THEN
    IF v_existing.discount_value IS NOT DISTINCT FROM v_promo.discount_percent
       AND v_existing.discount_amount IS NOT DISTINCT FROM v_amount
       AND v_existing.reason IS NOT DISTINCT FROM v_promo.name
       AND v_existing.coupon_code IS NOT DISTINCT FROM v_promo.id::text THEN
      RETURN v_existing;
    END IF;
    UPDATE public.order_discounts
    SET discount_value = v_promo.discount_percent,
        discount_amount = v_amount,
        reason = v_promo.name,
        coupon_code = v_promo.id::text,
        updated_at = now()
    WHERE id = v_existing.id
    RETURNING * INTO v_result;
  ELSE
    INSERT INTO public.order_discounts (
      restaurant_id, order_id, discount_type, discount_mode, discount_value,
      discount_amount, reason, coupon_code, proof_storage_path, applied_by,
      approved_via, status
    ) VALUES (
      p_store_id, p_order_id, 'promotion', 'percent', v_promo.discount_percent,
      v_amount, v_promo.name, v_promo.id::text,
      'system/promotion/' || v_promo.id::text, v_promo.created_by,
      'scheduled_promotion', 'active'
    ) RETURNING * INTO v_result;
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_store_order_promotions(
  p_store_id uuid,
  p_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order record;
  v_count integer := 0;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'PROMOTION_REFRESH_FORBIDDEN';
  END IF;
  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'PROMOTION_REFRESH_FORBIDDEN';
  END IF;

  FOR v_order IN
    SELECT id FROM public.orders
    WHERE restaurant_id = p_store_id
      AND status NOT IN ('completed', 'cancelled')
      AND COALESCE(order_purpose, 'customer') = 'customer'
  LOOP
    PERFORM public.sync_active_order_promotion(v_order.id, p_store_id, p_at);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_active_order_discount_for_item_change(
  p_order_id uuid,
  p_store_id uuid,
  p_reason text DEFAULT 'order_items_changed'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_discount public.order_discounts%ROWTYPE;
  v_count integer := 0;
BEGIN
  SELECT * INTO v_discount FROM public.order_discounts
  WHERE order_id = p_order_id AND restaurant_id = p_store_id AND status = 'active'
  FOR UPDATE;
  IF FOUND AND v_discount.approved_via <> 'scheduled_promotion' THEN
    UPDATE public.order_discounts SET status = 'voided',
      void_reason = COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'order_items_changed'),
      updated_at = now() WHERE id = v_discount.id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
  END IF;
  PERFORM public.sync_active_order_promotion(p_order_id, p_store_id, now());
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_order_promotion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  PERFORM public.sync_active_order_promotion(
    COALESCE(NEW.order_id, OLD.order_id),
    COALESCE(NEW.restaurant_id, OLD.restaurant_id),
    now()
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_order_promotion ON public.order_items;
CREATE TRIGGER trg_sync_order_promotion
AFTER INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.trg_sync_order_promotion();

-- Expose the same scheduled price to the public QR catalogue. The order RPC
-- continues to insert canonical menu prices; the order_items trigger records
-- the promotion as an auditable order-level discount.
CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_promotion record;
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

  SELECT p.id, p.name, p.discount_percent
  INTO v_promotion
  FROM public.store_promotions p
  WHERE p.restaurant_id = v_table.restaurant_id
    AND p.is_active = true
    AND p.starts_at <= now()
    AND p.ends_at > now()
    AND p.channel IN ('both', 'qr')
  ORDER BY p.starts_at DESC
  LIMIT 1;

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
    'original_price', mi.price,
    'price', CASE
      WHEN v_promotion.id IS NULL THEN mi.price
      ELSE round(mi.price * (100 - v_promotion.discount_percent) / 100, 0)
    END,
    'discount_percent', COALESCE(v_promotion.discount_percent, 0),
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
    'promotion_name', v_promotion.name,
    'promotion_discount_percent', COALESCE(v_promotion.discount_percent, 0),
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_store_promotion(uuid, uuid, text, numeric, timestamptz, timestamptz, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_store_promotion(uuid, uuid, text, numeric, timestamptz, timestamptz, boolean)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_active_order_promotion(uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_active_order_promotion(uuid, uuid, timestamptz)
  TO service_role;
REVOKE ALL ON FUNCTION public.refresh_store_order_promotions(uuid, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_store_order_promotions(uuid, timestamptz)
  TO authenticated, service_role;

-- pg_cron uses UTC: 16:00 UTC is 23:00 Asia/Ho_Chi_Minh.
DO $schedule$
DECLARE v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'daily-closing-2300-hcm' LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    PERFORM cron.schedule(
      'daily-closing-2300-hcm',
      '0 16 * * *',
      $command$SELECT public.run_scheduled_daily_closings()$command$
    );
  END IF;
END;
$schedule$;

COMMIT;
