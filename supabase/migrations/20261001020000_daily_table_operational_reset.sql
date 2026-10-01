-- The production apply wrapper and migration runner supply the transaction.
SET LOCAL lock_timeout = '5s';

-- Financial completion and operational closure are independent. Historical
-- table IDs, payments, quantities, inventory movements and receipts survive.
ALTER TABLE public.orders ADD COLUMN operational_closed_at timestamptz;
ALTER TABLE public.orders ADD COLUMN operational_close_reason text;
ALTER TABLE public.orders ADD CONSTRAINT orders_operational_close_pair CHECK (
  (operational_closed_at IS NULL AND operational_close_reason IS NULL)
  OR (operational_closed_at IS NOT NULL AND operational_close_reason IS NOT NULL
    AND operational_close_reason = 'business_day_expired')
);
CREATE INDEX orders_stale_table_operations ON public.orders(restaurant_id, created_at, id)
WHERE operational_closed_at IS NULL AND table_id IS NOT NULL
  AND sales_channel = 'dine_in' AND status IN ('pending', 'confirmed', 'serving');

CREATE TABLE public.table_operational_reset_policies (
  restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id),
  is_enabled boolean NOT NULL DEFAULT false,
  last_completed_date date,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.order_operational_closures (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  table_id uuid NOT NULL REFERENCES public.tables(id),
  table_number text NOT NULL,
  business_date date NOT NULL,
  closed_at timestamptz NOT NULL,
  closure_kind text NOT NULL CHECK (closure_kind IN ('unpaid_cancelled', 'financial_review')),
  close_source text NOT NULL DEFAULT 'business_day_reset' CHECK (close_source = 'business_day_reset'),
  payment_count integer NOT NULL CHECK (payment_count >= 0),
  paid_total numeric NOT NULL,
  cancelled_amount numeric NOT NULL CHECK (cancelled_amount >= 0),
  order_snapshot jsonb NOT NULL,
  item_snapshot jsonb NOT NULL,
  payment_snapshot jsonb NOT NULL,
  fulfillment_snapshot jsonb NOT NULL,
  print_snapshot jsonb NOT NULL,
  triggered_by uuid
);
CREATE INDEX order_operational_closures_store_date
ON public.order_operational_closures(restaurant_id, closed_at DESC);

ALTER TABLE public.table_operational_reset_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_operational_closures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.table_operational_reset_policies, public.order_operational_closures
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.table_operational_reset_policies TO authenticated;
GRANT SELECT ON public.order_operational_closures TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.table_operational_reset_policies TO service_role;
GRANT SELECT ON public.order_operational_closures TO service_role;
CREATE POLICY table_reset_scoped_read ON public.table_operational_reset_policies
FOR SELECT TO authenticated USING (
  public.is_super_admin() OR EXISTS (
    SELECT 1 FROM public.user_accessible_stores((SELECT auth.uid())) s(store_id)
    WHERE s.store_id = restaurant_id
  )
);
CREATE POLICY operational_closure_management_read ON public.order_operational_closures
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = (SELECT auth.uid())
    AND u.is_active AND u.role IN ('cashier','admin','store_admin','brand_admin','super_admin'))
  AND (public.is_super_admin() OR EXISTS (
    SELECT 1 FROM public.user_accessible_stores((SELECT auth.uid())) s(store_id)
    WHERE s.store_id = restaurant_id
  ))
);
CREATE FUNCTION public.prevent_operational_closure_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
BEGIN RAISE EXCEPTION 'OPERATIONAL_CLOSURE_IMMUTABLE'; END;
$$;
CREATE TRIGGER operational_closure_immutable BEFORE UPDATE OR DELETE
ON public.order_operational_closures FOR EACH ROW
EXECUTE FUNCTION public.prevent_operational_closure_mutation();

CREATE FUNCTION public.table_order_is_current(p_order public.orders) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT p_order.operational_closed_at IS NULL AND (
    p_order.table_id IS NULL OR p_order.sales_channel IS DISTINCT FROM 'dine_in'
    OR NOT EXISTS (SELECT 1 FROM public.table_operational_reset_policies p
      WHERE p.restaurant_id = p_order.restaurant_id AND p.is_enabled)
    OR p_order.created_at >= ((statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
      AT TIME ZONE 'Asia/Ho_Chi_Minh')
  )
$$;
REVOKE ALL ON FUNCTION public.table_order_is_current(public.orders) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.table_order_is_current(public.orders) TO authenticated, service_role;

-- The internal timestamp is only available to trusted server callers/tests.
-- Authenticated and QR entry points always supply the actual server time.
CREATE FUNCTION public.close_expired_table_operations_at(p_store_id uuid, p_observed_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE
  v_date date := (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_start timestamptz := v_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_order public.orders%ROWTYPE;
  v_table public.tables%ROWTYPE;
  v_payment_count integer;
  v_paid numeric;
  v_amount numeric;
  v_items jsonb;
  v_payments jsonb;
  v_closed integer := 0;
  v_review integer := 0;
  v_repaired integer := 0;
  v_remaining boolean;
BEGIN
  IF p_observed_at IS NULL OR p_store_id IS NULL THEN RAISE EXCEPTION 'RESET_INPUT_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.table_operational_reset_policies p
    JOIN public.restaurants r ON r.id=p.restaurant_id
    WHERE p.restaurant_id=p_store_id AND p.is_enabled AND r.is_active) THEN
    RETURN jsonb_build_object('enabled',false);
  END IF;
  IF EXISTS (SELECT 1 FROM public.table_operational_reset_policies p WHERE p.restaurant_id=p_store_id
      AND p.last_completed_date=v_date AND p.last_attempt_at>p_observed_at-interval '5 minutes')
    AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.restaurant_id=p_store_id
      AND o.table_id IS NOT NULL AND o.sales_channel='dine_in' AND o.operational_closed_at IS NULL
      AND o.status IN ('pending','confirmed','serving') AND o.created_at<v_start) THEN
    RETURN jsonb_build_object('enabled',true);
  END IF;
  -- Never wait for another reset while holding an order lock in a QR request.
  IF NOT pg_try_advisory_xact_lock(hashtextextended('table-day-reset:' || p_store_id::text,0)) THEN
    RETURN jsonb_build_object('enabled',true,'busy',true);
  END IF;
  UPDATE public.table_operational_reset_policies
  SET last_attempt_at=p_observed_at,updated_at=p_observed_at WHERE restaurant_id=p_store_id;

  FOR v_order IN SELECT o.* FROM public.orders o
    WHERE o.restaurant_id=p_store_id AND o.table_id IS NOT NULL AND o.sales_channel='dine_in'
      AND o.operational_closed_at IS NULL AND o.status IN ('pending','confirmed','serving')
      AND o.created_at < v_start ORDER BY o.created_at,o.id FOR UPDATE SKIP LOCKED
  LOOP
    SELECT count(*),COALESCE(sum(p.amount),0) INTO v_payment_count,v_paid
    FROM public.payments p WHERE p.order_id=v_order.id;
    SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.created_at,i.id),'[]'::jsonb),
      COALESCE(sum(CASE WHEN i.status='cancelled' OR i.is_service_item THEN 0
        WHEN COALESCE(i.paying_amount_inc_tax,0)>0 THEN i.paying_amount_inc_tax
        ELSE i.unit_price*i.quantity END),0)
    INTO v_items,v_amount FROM public.order_items i WHERE i.order_id=v_order.id;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,
      'method',p.method,'is_revenue',p.is_revenue,'created_at',p.created_at) ORDER BY p.created_at,p.id),'[]'::jsonb)
    INTO v_payments FROM public.payments p WHERE p.order_id=v_order.id;
    SELECT * INTO STRICT v_table FROM public.tables WHERE id=v_order.table_id;

    INSERT INTO public.order_operational_closures(
      order_id,restaurant_id,table_id,table_number,business_date,closed_at,closure_kind,
      payment_count,paid_total,cancelled_amount,order_snapshot,item_snapshot,payment_snapshot,
      fulfillment_snapshot,print_snapshot,triggered_by
    ) VALUES (
      v_order.id,p_store_id,v_order.table_id,v_table.table_number,
      (v_order.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,p_observed_at,
      CASE WHEN v_payment_count=0 THEN 'unpaid_cancelled' ELSE 'financial_review' END,
      v_payment_count,v_paid,CASE WHEN v_payment_count=0 THEN v_amount ELSE 0 END,
      to_jsonb(v_order),v_items,v_payments,
      jsonb_build_object(
        'base',(SELECT COALESCE(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM public.emergency_fulfillment_items f WHERE f.order_id=v_order.id),
        'combo',(SELECT COALESCE(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM public.emergency_combo_component_items f WHERE f.order_id=v_order.id),
        'direct',(SELECT COALESCE(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM public.emergency_floor_direct_items f WHERE f.order_id=v_order.id)),
      (SELECT COALESCE(jsonb_agg(to_jsonb(j)),'[]'::jsonb) FROM public.print_jobs j WHERE j.order_id=v_order.id),auth.uid()
    );
    -- Mark the parent first so existing item triggers cannot derive it open.
    UPDATE public.orders SET operational_closed_at=p_observed_at,
      operational_close_reason='business_day_expired',updated_at=p_observed_at,
      status=CASE WHEN v_payment_count=0 THEN 'cancelled' ELSE status END
    WHERE id=v_order.id;
    IF v_payment_count=0 THEN
      UPDATE public.order_items SET status='cancelled'
      WHERE order_id=v_order.id AND status IN ('pending','preparing','ready','served');
      v_closed:=v_closed+1;
    ELSE v_review:=v_review+1;
    END IF;
    -- Cancel remaining fulfillment, preserving all already recorded counters.
    UPDATE public.emergency_fulfillment_items SET is_cancelled=true,updated_at=p_observed_at
    WHERE order_id=v_order.id AND NOT is_cancelled;
    UPDATE public.emergency_combo_component_items SET is_cancelled=true,updated_at=p_observed_at
    WHERE order_id=v_order.id AND NOT is_cancelled;
    UPDATE public.emergency_floor_direct_items SET is_cancelled=true,updated_at=p_observed_at
    WHERE order_id=v_order.id AND NOT is_cancelled;
    UPDATE public.emergency_floor_ready_lots
    SET voided_quantity=ready_quantity-served_quantity,updated_at=p_observed_at
    WHERE order_id=v_order.id AND served_quantity+voided_quantity<ready_quantity;
    UPDATE public.leftover_packaging_requests SET status='cancelled',updated_at=p_observed_at
    WHERE order_id=v_order.id AND status NOT IN ('completed','cancelled');
    UPDATE public.print_jobs SET status='cancelled',updated_at=p_observed_at
    WHERE order_id=v_order.id AND status IN ('pending','failed')
      AND COALESCE(copy_type::text,'') NOT IN ('receipt','delivery_driver_receipt');
    UPDATE public.customer_payment_displays
    SET order_id=NULL,status='idle',payload=NULL,shown_by_user_id=NULL,shown_at=NULL,updated_at=p_observed_at
    WHERE store_id=p_store_id AND order_id=v_order.id AND COALESCE(payload->>'phase','payment')='payment';
    INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
    VALUES (NULL,'close_expired_table_operations','orders',v_order.id,
      jsonb_build_object('store_id',p_store_id,'source','system','triggered_by',auth.uid(),
        'business_date',(v_order.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        'payment_count',v_payment_count,'paid_total',v_paid,'closed_at',p_observed_at));
  END LOOP;

  -- Table locks are last, matching the order -> table payment lock sequence.
  -- Locked operations are retried; today's order always wins over a reset.
  FOR v_table IN SELECT t.* FROM public.tables t
    WHERE t.restaurant_id=p_store_id AND t.status='occupied'
    ORDER BY t.id FOR UPDATE SKIP LOCKED
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.table_id=v_table.id
      AND o.status IN ('pending','confirmed','serving') AND o.operational_closed_at IS NULL
      AND (o.sales_channel IS DISTINCT FROM 'dine_in' OR o.created_at>=v_start)) THEN
      UPDATE public.tables SET status='available',updated_at=p_observed_at WHERE id=v_table.id;
      INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
      VALUES (NULL,'repair_table_operational_status','tables',v_table.id,
        jsonb_build_object('store_id',p_store_id,'source','system','from_status','occupied','to_status','available'));
      v_repaired:=v_repaired+1;
    END IF;
  END LOOP;
  SELECT EXISTS (SELECT 1 FROM public.orders o WHERE o.restaurant_id=p_store_id
    AND o.table_id IS NOT NULL AND o.sales_channel='dine_in' AND o.operational_closed_at IS NULL
    AND o.status IN ('pending','confirmed','serving') AND o.created_at<v_start) INTO v_remaining;
  UPDATE public.table_operational_reset_policies SET
    last_completed_date=CASE WHEN NOT v_remaining THEN v_date ELSE last_completed_date END,
    last_success_at=CASE WHEN NOT v_remaining THEN p_observed_at ELSE last_success_at END,
    last_error=NULL,updated_at=p_observed_at WHERE restaurant_id=p_store_id;
  RETURN jsonb_build_object('enabled',true,'closed_count',v_closed,'review_count',v_review,
    'repaired_table_count',v_repaired,'pending',v_remaining);
END;
$$;
REVOKE ALL ON FUNCTION public.close_expired_table_operations_at(uuid,timestamptz)
FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.ensure_store_operational_day(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb; v_now timestamptz:=clock_timestamp();
  v_date date:=(v_now AT TIME ZONE 'Asia/Ho_Chi_Minh')::date; v_reviews jsonb; v_cancelled integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND (
    NOT EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active)
    OR (NOT COALESCE(public.is_super_admin(),false) AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id))) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;
  -- The partial index makes the normal, already-clean day an inexpensive check.
  IF EXISTS (SELECT 1 FROM public.table_operational_reset_policies WHERE restaurant_id=p_store_id
      AND is_enabled AND last_completed_date=v_date)
    AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.restaurant_id=p_store_id
      AND o.table_id IS NOT NULL AND o.sales_channel='dine_in' AND o.operational_closed_at IS NULL
      AND o.status IN ('pending','confirmed','serving')
      AND o.created_at<v_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh') THEN
    v_result:=jsonb_build_object('enabled',true);
  ELSE v_result:=public.close_expired_table_operations_at(p_store_id,v_now);
  END IF;
  v_reviews:='[]'::jsonb; v_cancelled:=0;
  IF auth.role()='service_role' OR EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid()
    AND is_active AND role IN ('cashier','admin','store_admin','brand_admin','super_admin')) THEN
    SELECT count(*) INTO v_cancelled FROM public.order_operational_closures
    WHERE restaurant_id=p_store_id AND closure_kind='unpaid_cancelled'
      AND closed_at>=v_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
    SELECT COALESCE(jsonb_agg(to_jsonb(s)),'[]'::jsonb) INTO v_reviews FROM (
      SELECT c.order_id,c.table_number,c.business_date,c.paid_total,
        c.order_snapshot->>'status' AS order_status,c.closed_at
      FROM public.order_operational_closures c JOIN public.orders o ON o.id=c.order_id
      WHERE c.restaurant_id=p_store_id AND c.closure_kind='financial_review'
        AND o.status NOT IN ('completed','cancelled') ORDER BY c.closed_at DESC LIMIT 50
    ) s;
  END IF;
  RETURN v_result || jsonb_build_object('business_date',v_date,
    'day_start',v_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh',
    'day_end',(v_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh',
    'observed_at',v_now,'cancelled_today',v_cancelled,'financial_reviews',v_reviews);
END;
$$;
REVOKE ALL ON FUNCTION public.ensure_store_operational_day(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_store_operational_day(uuid) TO authenticated,service_role;

CREATE FUNCTION public.run_daily_table_operational_resets() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_policy record; v_results jsonb:='[]'::jsonb; v_result jsonb;
BEGIN
  FOR v_policy IN SELECT p.restaurant_id FROM public.table_operational_reset_policies p
    JOIN public.restaurants r ON r.id=p.restaurant_id WHERE p.is_enabled AND r.is_active
    ORDER BY p.restaurant_id LOOP
    BEGIN
      v_result:=public.close_expired_table_operations_at(v_policy.restaurant_id,clock_timestamp());
      v_results:=v_results || jsonb_build_array(v_result || jsonb_build_object('store_id',v_policy.restaurant_id));
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.table_operational_reset_policies SET last_error=SQLERRM,
        last_attempt_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE restaurant_id=v_policy.restaurant_id;
      v_results:=v_results || jsonb_build_array(jsonb_build_object('store_id',v_policy.restaurant_id,'error',SQLERRM));
    END;
  END LOOP;
  RETURN v_results;
END;
$$;
REVOKE ALL ON FUNCTION public.run_daily_table_operational_resets() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.run_daily_table_operational_resets() TO service_role;

-- Existing sales reports include system cancellations as well as manual
-- cancellations. Each source has its own immutable ledger and actor contract.
CREATE OR REPLACE FUNCTION public.get_store_sales_cancellation_total(
  p_store_id uuid,p_start_at timestamptz,p_end_at timestamptz
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
  SELECT COALESCE(sum(source.amount),0)::numeric FROM (
    SELECT l.cancelled_amount AS amount FROM public.order_cancellation_ledger l
    LEFT JOIN public.order_cancellation_reversals r ON r.cancellation_ledger_id=l.id
    WHERE l.restaurant_id=p_store_id AND l.created_at>=p_start_at AND l.created_at<=p_end_at AND r.id IS NULL
    UNION ALL
    SELECT c.cancelled_amount FROM public.order_operational_closures c
    WHERE c.restaurant_id=p_store_id AND c.closure_kind='unpaid_cancelled'
      AND c.closed_at>=p_start_at AND c.closed_at<=p_end_at
  ) source WHERE public.is_super_admin() OR EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id
  )
$$;
REVOKE ALL ON FUNCTION public.get_store_sales_cancellation_total(uuid,timestamptz,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_store_sales_cancellation_total(uuid,timestamptz,timestamptz) TO authenticated;

-- Central guards protect legacy clients, restore RPCs and late station writes.
CREATE FUNCTION public.guard_order_operational_closure() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF OLD.operational_closed_at IS NOT NULL AND (
    NEW.operational_closed_at IS DISTINCT FROM OLD.operational_closed_at
    OR NEW.operational_close_reason IS DISTINCT FROM OLD.operational_close_reason
    OR NEW.table_id IS DISTINCT FROM OLD.table_id OR NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id
    OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.status IS DISTINCT FROM OLD.status) THEN
    RAISE EXCEPTION 'ORDER_OPERATIONS_CLOSED';
  END IF;
  IF NEW.operational_closed_at IS NOT NULL AND OLD.operational_closed_at IS NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.order_operational_closures c
      WHERE c.order_id=OLD.id AND c.closed_at=NEW.operational_closed_at AND c.restaurant_id=NEW.restaurant_id) THEN
      RAISE EXCEPTION 'ORDER_CLOSURE_LEDGER_REQUIRED';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT public.table_order_is_current(OLD) AND NEW.status IN ('pending','confirmed','serving')
    AND OLD.status IN ('completed','cancelled') THEN RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED'; END IF;
  IF NOT public.table_order_is_current(OLD) AND OLD.status NOT IN ('completed','cancelled')
     AND NEW.status IS DISTINCT FROM 'cancelled'
     AND (to_jsonb(NEW)-'updated_at') IS DISTINCT FROM (to_jsonb(OLD)-'updated_at') THEN
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_order_operational_closure BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.guard_order_operational_closure();

CREATE FUNCTION public.guard_order_item_operational_day() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id FOR UPDATE NOWAIT;
  IF FOUND AND NOT public.table_order_is_current(v_order) THEN
    IF TG_OP='UPDATE' AND NEW.status='cancelled'
      AND (to_jsonb(NEW)-'status'-'updated_at')=(to_jsonb(OLD)-'status'-'updated_at') THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER aa_guard_order_item_operational_day BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.guard_order_item_operational_day();

CREATE FUNCTION public.guard_fulfillment_operational_day() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id FOR UPDATE NOWAIT;
  IF FOUND AND NOT public.table_order_is_current(v_order) THEN
    IF TG_OP='UPDATE' AND NEW.is_cancelled
      AND (to_jsonb(NEW)-'is_cancelled'-'updated_at')=(to_jsonb(OLD)-'is_cancelled'-'updated_at') THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER aa_guard_fulfillment_operational_day BEFORE INSERT OR UPDATE ON public.emergency_fulfillment_items
FOR EACH ROW EXECUTE FUNCTION public.guard_fulfillment_operational_day();
CREATE TRIGGER aa_guard_combo_operational_day BEFORE INSERT OR UPDATE ON public.emergency_combo_component_items
FOR EACH ROW EXECUTE FUNCTION public.guard_fulfillment_operational_day();
CREATE TRIGGER aa_guard_direct_operational_day BEFORE INSERT OR UPDATE ON public.emergency_floor_direct_items
FOR EACH ROW EXECUTE FUNCTION public.guard_fulfillment_operational_day();

-- Child writes serialize with closure without waiting while already holding
-- a child lock. A busy parent rejects the late event for a safe client retry.
CREATE FUNCTION public.guard_pending_operation_day() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  -- Historical payment receipts remain printable after operational closure.
  IF TG_TABLE_NAME='print_jobs' THEN
    IF NEW.copy_type IN ('receipt','delivery_driver_receipt') THEN RETURN NEW; END IF;
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id FOR UPDATE NOWAIT;
  IF FOUND AND NOT public.table_order_is_current(v_order) THEN
    IF TG_OP='UPDATE' THEN
      IF TG_TABLE_NAME='emergency_floor_ready_lots' THEN
        IF NEW.voided_quantity=NEW.ready_quantity-NEW.served_quantity
          AND (to_jsonb(NEW)-'voided_quantity'-'updated_at')=(to_jsonb(OLD)-'voided_quantity'-'updated_at') THEN RETURN NEW; END IF;
      ELSIF NEW.status='cancelled'
        AND (to_jsonb(NEW)-'status'-'updated_at')=(to_jsonb(OLD)-'status'-'updated_at') THEN RETURN NEW;
      END IF;
    END IF;
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER aa_guard_ready_lot_operational_day BEFORE INSERT OR UPDATE ON public.emergency_floor_ready_lots
FOR EACH ROW EXECUTE FUNCTION public.guard_pending_operation_day();
CREATE TRIGGER aa_guard_leftover_operational_day BEFORE INSERT OR UPDATE ON public.leftover_packaging_requests
FOR EACH ROW EXECUTE FUNCTION public.guard_pending_operation_day();
CREATE TRIGGER aa_guard_print_operational_day BEFORE INSERT OR UPDATE ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.guard_pending_operation_day();

CREATE FUNCTION public.guard_table_release_current_order() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF NEW.status='available' AND EXISTS (SELECT 1 FROM public.orders o
    WHERE o.table_id=NEW.id AND o.status IN ('pending','confirmed','serving')
      AND public.table_order_is_current(o)) THEN NEW.status:='occupied'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_table_release_current_order BEFORE UPDATE OF status ON public.tables
FOR EACH ROW EXECUTE FUNCTION public.guard_table_release_current_order();

CREATE FUNCTION public.guard_payment_operational_day() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id FOR UPDATE;
  IF FOUND AND NOT public.table_order_is_current(v_order) THEN RAISE EXCEPTION 'ORDER_OPERATIONS_CLOSED'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER aa_guard_payment_operational_day BEFORE INSERT ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.guard_payment_operational_day();

REVOKE ALL ON FUNCTION public.prevent_operational_closure_mutation(),
  public.guard_order_operational_closure(),public.guard_order_item_operational_day(),
  public.guard_fulfillment_operational_day(),public.guard_pending_operation_day(),
  public.guard_table_release_current_order(),public.guard_payment_operational_day()
FROM PUBLIC,anon,authenticated,service_role;

-- Preserve substantial legacy pricing/printing/promotion bodies. Patch only
-- the known active-order clauses in the full deployed QR wrapper chain.
CREATE TABLE public.daily_table_reset_function_backup (
  object_identity text PRIMARY KEY, definition text NOT NULL
);
ALTER TABLE public.daily_table_reset_function_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.daily_table_reset_function_backup FROM PUBLIC,anon,authenticated,service_role;
DO $patch$
DECLARE v_proc record; v_def text; v_new text;
BEGIN
  FOR v_proc IN SELECT p.oid,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND (
      p.proname LIKE 'qr_get_active_order%' OR p.proname LIKE 'qr_place_order%'
      OR p.proname LIKE 'cancel_order%' OR p.proname LIKE 'restore_cancelled_order%'
      OR p.proname='recalc_order_status') LOOP
    v_def:=pg_get_functiondef(v_proc.oid);
    IF v_proc.proname='recalc_order_status' THEN
      v_new:=replace(v_def,'IF v_order.status IN (''completed'', ''cancelled'') THEN',
        'IF v_order.operational_closed_at IS NOT NULL OR v_order.status IN (''completed'', ''cancelled'') THEN');
    ELSE v_new:=v_def;
    END IF;
      v_new:=replace(v_new,'AND order_row.status IN (''pending'', ''confirmed'', ''serving'')',
        'AND order_row.status IN (''pending'', ''confirmed'', ''serving'') AND public.table_order_is_current(order_row)');
      v_new:=replace(v_new,'AND o.status IN (''pending'', ''confirmed'', ''serving'')',
        'AND o.status IN (''pending'', ''confirmed'', ''serving'') AND public.table_order_is_current(o)');
      v_new:=replace(v_new,'AND other_order.status IN (''pending'', ''confirmed'', ''serving'')',
        'AND other_order.status IN (''pending'', ''confirmed'', ''serving'') AND public.table_order_is_current(other_order)');
      v_new:=replace(v_new,'AND status IN (''pending'', ''confirmed'', ''serving'')',
        'AND status IN (''pending'', ''confirmed'', ''serving'') AND public.table_order_is_current(orders)');
    IF v_new IS DISTINCT FROM v_def THEN
      INSERT INTO public.daily_table_reset_function_backup VALUES(v_proc.oid::regprocedure::text,v_def);
      EXECUTE v_new;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.daily_table_reset_function_backup
    WHERE object_identity='qr_place_order_pre_takeout_core(text,jsonb,uuid)')
    OR NOT EXISTS (SELECT 1 FROM public.daily_table_reset_function_backup
    WHERE object_identity='recalc_order_status(uuid)') THEN RAISE EXCEPTION 'DAILY_TABLE_RESET_PATCH_FAILED'; END IF;
END;
$patch$;

ALTER FUNCTION public.create_order(uuid,uuid,jsonb) RENAME TO create_order_before_daily_reset;
REVOKE ALL ON FUNCTION public.create_order_before_daily_reset(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.create_order(p_store_id uuid,p_table_id uuid,p_items jsonb) RETURNS public.orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
BEGIN
  PERFORM public.ensure_store_operational_day(p_store_id);
  RETURN public.create_order_before_daily_reset(p_store_id,p_table_id,p_items);
END;
$$;
REVOKE ALL ON FUNCTION public.create_order(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_order(uuid,uuid,jsonb) TO authenticated,service_role;

ALTER FUNCTION public.qr_get_active_order(text) RENAME TO qr_get_active_order_before_daily_reset;
REVOKE ALL ON FUNCTION public.qr_get_active_order_before_daily_reset(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.qr_get_active_order(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,pg_catalog AS $$
DECLARE v_store uuid;
BEGIN
  SELECT q.restaurant_id INTO v_store FROM public.table_qr_tokens q
  JOIN public.restaurants r ON r.id=q.restaurant_id AND r.is_active
  WHERE q.token=NULLIF(btrim(COALESCE(p_token,'')),'') AND q.is_active;
  IF v_store IS NULL THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;
  PERFORM public.close_expired_table_operations_at(v_store,clock_timestamp());
  RETURN public.qr_get_active_order_before_daily_reset(p_token);
END;
$$;
REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text) TO anon,authenticated,service_role;

ALTER FUNCTION public.qr_place_order(text,jsonb,uuid,boolean,uuid) RENAME TO qr_place_order_before_daily_reset;
REVOKE ALL ON FUNCTION public.qr_place_order_before_daily_reset(text,jsonb,uuid,boolean,uuid)
FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.qr_place_order(p_token text,p_items jsonb,p_client_order_id uuid,
  p_validate_combo_choices boolean,p_expected_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,pg_catalog AS $$
DECLARE v_store uuid;
BEGIN
  SELECT q.restaurant_id INTO v_store FROM public.table_qr_tokens q
  JOIN public.restaurants r ON r.id=q.restaurant_id AND r.is_active
  WHERE q.token=NULLIF(btrim(COALESCE(p_token,'')),'') AND q.is_active;
  IF v_store IS NULL THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;
  PERFORM public.close_expired_table_operations_at(v_store,clock_timestamp());
  RETURN public.qr_place_order_before_daily_reset(p_token,p_items,p_client_order_id,
    p_validate_combo_choices,p_expected_order_id);
END;
$$;
REVOKE ALL ON FUNCTION public.qr_place_order(text,jsonb,uuid,boolean,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_place_order(text,jsonb,uuid,boolean,uuid) TO anon,authenticated,service_role;

ALTER FUNCTION public.create_buffet_order(uuid,uuid,integer,jsonb) RENAME TO create_buffet_order_before_daily_reset;
REVOKE ALL ON FUNCTION public.create_buffet_order_before_daily_reset(uuid,uuid,integer,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.create_buffet_order(p_store_id uuid,p_table_id uuid,p_guest_count integer,p_extra_items jsonb DEFAULT '[]'::jsonb)
RETURNS public.orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
  PERFORM public.ensure_store_operational_day(p_store_id);
  RETURN public.create_buffet_order_before_daily_reset(p_store_id,p_table_id,p_guest_count,p_extra_items);
END;
$$;
REVOKE ALL ON FUNCTION public.create_buffet_order(uuid,uuid,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_buffet_order(uuid,uuid,integer,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.create_order_for_business_day(p_store_id uuid,p_table_id uuid,p_items jsonb,
  p_client_mutation_id text,p_business_date date) RETURNS public.orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  PERFORM public.ensure_store_operational_day(p_store_id);
  IF EXISTS (SELECT 1 FROM public.table_operational_reset_policies WHERE restaurant_id=p_store_id AND is_enabled)
    AND p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED';
  END IF;
  IF NULLIF(btrim(COALESCE(p_client_mutation_id,'')),'') IS NULL THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED';
  END IF;
  -- Some deployed databases use the client's existing create_order fallback
  -- without the optional idempotency RPC/ledger. Keep the day validation on
  -- that path as well; do not require an unrelated historical rollout.
  IF to_regprocedure('public.create_order_with_client_mutation_id(uuid,uuid,jsonb,text)') IS NOT NULL THEN
    v_order:=public.create_order_with_client_mutation_id(p_store_id,p_table_id,p_items,p_client_mutation_id);
  ELSE
    v_order:=public.create_order(p_store_id,p_table_id,p_items);
  END IF;
  IF NOT public.table_order_is_current(v_order) THEN RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED'; END IF;
  RETURN v_order;
END;
$$;
REVOKE ALL ON FUNCTION public.create_order_for_business_day(uuid,uuid,jsonb,text,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_order_for_business_day(uuid,uuid,jsonb,text,date) TO authenticated,service_role;

CREATE FUNCTION public.cancel_current_table_order(p_store_id uuid,p_table_id uuid,p_reason text)
RETURNS public.orders LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_order public.orders%ROWTYPE; v_result public.orders%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active
    AND role IN ('cashier','admin','store_admin','brand_admin','super_admin')) THEN RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN'; END IF;
  IF length(btrim(COALESCE(p_reason,'')))<3 THEN RAISE EXCEPTION 'ORDER_CANCEL_REASON_REQUIRED'; END IF;
  PERFORM public.ensure_store_operational_day(p_store_id);
  SELECT * INTO v_order FROM public.orders o WHERE o.restaurant_id=p_store_id AND o.table_id=p_table_id
    AND o.status IN ('pending','confirmed','serving') AND public.table_order_is_current(o)
    ORDER BY o.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  v_result:=public.cancel_order(v_order.id,p_store_id,false);
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  VALUES(auth.uid(),'cancel_current_table_order','orders',v_order.id,
    jsonb_build_object('store_id',p_store_id,'table_id',p_table_id,'reason',btrim(p_reason)));
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_current_table_order(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_current_table_order(uuid,uuid,text) TO authenticated;

-- UTC cron: 17:00 is Vietnam midnight. Retry every five minutes also repairs
-- missed runs and orphan occupancy; no existing financial close job changes.
DO $cron$
BEGIN
  IF EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='cron') THEN
    PERFORM cron.schedule('table-operational-day-reset-0000-hcm','*/5 * * * *',
      'SELECT public.run_daily_table_operational_resets()');
  END IF;
END;
$cron$;
NOTIFY pgrst,'reload schema';
