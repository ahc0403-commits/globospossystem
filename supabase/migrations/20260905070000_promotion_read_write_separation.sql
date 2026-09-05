BEGIN;
SET LOCAL lock_timeout = '3s';

-- One private scheduler cursor, never exposed through the client API/feed.
CREATE TABLE IF NOT EXISTS public.promotion_schedule_cursor (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  checked_at timestamptz
);
ALTER TABLE public.promotion_schedule_cursor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.promotion_schedule_cursor FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO public.promotion_schedule_cursor(singleton) VALUES (true) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.run_due_store_promotions()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_last timestamptz; v_at timestamptz := now(); v_store uuid; v_order uuid; v_count integer := 0;
BEGIN
  -- Concurrent scheduler invocations never repeat the same boundary work.
  IF NOT pg_try_advisory_xact_lock(825911, 1) THEN RETURN 0; END IF;
  SELECT checked_at INTO v_last FROM public.promotion_schedule_cursor WHERE singleton FOR UPDATE;
  FOR v_store IN
    SELECT DISTINCT restaurant_id FROM public.store_promotions
    WHERE v_last IS NULL
      OR (starts_at > v_last AND starts_at <= v_at)
      OR (ends_at > v_last AND ends_at <= v_at)
      OR (updated_at > v_last AND updated_at <= v_at)
  LOOP
    FOR v_order IN SELECT id FROM public.orders
      WHERE restaurant_id = v_store AND status NOT IN ('completed','cancelled')
        AND coalesce(order_purpose,'customer')='customer'
        AND created_at >= ((v_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
        AND created_at < (((v_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
      ORDER BY id
    LOOP
      PERFORM public.sync_active_order_promotion(v_order,v_store,v_at);
      v_count := v_count + 1;
    END LOOP;
  END LOOP;
  UPDATE public.promotion_schedule_cursor SET checked_at=v_at WHERE singleton;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.run_due_store_promotions() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.run_due_store_promotions() TO service_role;

CREATE OR REPLACE FUNCTION public.order_promotion_fingerprint(p_order_id uuid,p_store_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public,pg_catalog AS $$
  SELECT jsonb_build_object('type',d.discount_type,'mode',d.discount_mode,
    'value',d.discount_value,'amount',d.discount_amount,'via',d.approved_via,
    'lines',coalesce((SELECT jsonb_agg(jsonb_build_object('item',l.order_item_id,
      'amount',l.discount_amount,'percent',l.discount_percent) ORDER BY l.order_item_id)
      FROM public.order_discount_lines l WHERE l.order_discount_id=d.id),'[]'::jsonb))
  FROM public.order_discounts d
  WHERE d.order_id=p_order_id AND d.restaurant_id=p_store_id AND d.status='active'
$$;
REVOKE ALL ON FUNCTION public.order_promotion_fingerprint(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

-- An explicit payment-attempt recovery action; never called by loadOrders.
CREATE OR REPLACE FUNCTION public.prepare_order_payment_promotions(p_store_id uuid,p_order_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_order uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active=true
    AND role IN ('cashier','admin','store_admin','brand_admin','super_admin'))
    OR p_store_id IS NULL OR (NOT coalesce(public.is_super_admin(),false) AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(id) WHERE s.id=p_store_id
    )) THEN RAISE EXCEPTION 'PAYMENT_FORBIDDEN'; END IF;
  IF coalesce(cardinality(p_order_ids),0) NOT BETWEEN 1 AND 100
    OR array_ndims(p_order_ids)<>1 OR EXISTS (SELECT 1 FROM unnest(p_order_ids) o(id) WHERE id IS NULL) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
  END IF;
  FOR v_order IN SELECT DISTINCT id FROM unnest(p_order_ids) o(id) ORDER BY id LOOP
    PERFORM public.sync_active_order_promotion(v_order,p_store_id,now());
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.prepare_order_payment_promotions(uuid,uuid[]) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.prepare_order_payment_promotions(uuid,uuid[]) TO authenticated,service_role;

-- Preserve the existing scoped/VAT/atomic payment implementation verbatim.
DO $$ BEGIN
  IF to_regprocedure('public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)') IS NULL THEN
    ALTER FUNCTION public.process_payment(uuid,uuid,numeric,text) RENAME TO process_payment_before_promotion_read_split;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)
  FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.process_payment(p_order_id uuid,p_store_id uuid,p_amount numeric,p_method text)
RETURNS public.payments LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_before jsonb;
BEGIN
  -- Reuse the explicit action's role/store check before touching promotion rows.
  -- Existing active-discount lock order is retained; no new order lock is added.
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active=true
    AND role IN ('cashier','admin','store_admin','brand_admin','super_admin'))
    OR p_store_id IS NULL OR (NOT coalesce(public.is_super_admin(),false) AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(id) WHERE s.id=p_store_id
    )) THEN RAISE EXCEPTION 'PAYMENT_FORBIDDEN'; END IF;
  PERFORM id FROM public.order_discounts WHERE order_id=p_order_id
    AND restaurant_id=p_store_id AND status='active' FOR UPDATE;
  v_before := public.order_promotion_fingerprint(p_order_id,p_store_id);
  PERFORM public.sync_active_order_promotion(p_order_id,p_store_id,now());
  IF v_before IS DISTINCT FROM public.order_promotion_fingerprint(p_order_id,p_store_id) THEN
    -- Roll back the whole attempt, including synchronization. The client performs
    -- one explicit preparation action and asks the cashier to review/re-submit.
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH' USING DETAIL = 'PROMOTION_PRICE_CHANGED';
  END IF;
  RETURN public.process_payment_before_promotion_read_split(p_order_id,p_store_id,p_amount,p_method);
END $$;
REVOKE ALL ON FUNCTION public.process_payment(uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid,uuid,numeric,text) TO authenticated,service_role;

-- Existing discount -> pos_live_events('orders') trigger refreshes connected
-- cashiers after actual boundary writes. The resulting load is read-only.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    RAISE EXCEPTION 'PROMOTION_SCHEDULER_REQUIRES_PG_CRON';
  END IF;
  PERFORM cron.schedule('promotion-boundaries', '* * * * *', 'select public.run_due_store_promotions();');
END $$;
COMMIT;
