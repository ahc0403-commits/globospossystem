BEGIN;

-- production-gate: self-verifying

ALTER TABLE public.daily_closings
  ADD COLUMN IF NOT EXISTS payments_bank_transfer numeric(15,2)
    NOT NULL DEFAULT 0 CHECK (payments_bank_transfer >= 0);

-- Historical closing code grouped bank transfer into payments_pay. Split that
-- immutable snapshot bucket using only payments that existed when the snapshot
-- was written.
WITH historical_bank AS (
  SELECT closing.id AS closing_id,
    COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)), 0)
      AS bank_total
  FROM public.daily_closings closing
  LEFT JOIN public.payments payment
    ON payment.restaurant_id = closing.restaurant_id
   AND payment.is_revenue = true
   AND lower(payment.method) = 'banktransfer'
   AND payment.created_at >=
     closing.closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND payment.created_at < LEAST(
     (closing.closing_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh',
     closing.created_at
   )
  WHERE closing.payments_bank_transfer = 0
  GROUP BY closing.id
)
UPDATE public.daily_closings closing
SET payments_bank_transfer = historical.bank_total,
    payments_pay = GREATEST(closing.payments_pay - historical.bank_total, 0)
FROM historical_bank historical
WHERE closing.id = historical.closing_id;

CREATE OR REPLACE FUNCTION public.create_daily_closing(
  p_store_id uuid,
  p_notes text DEFAULT NULL,
  p_cash_denominations jsonb DEFAULT '{}'::jsonb,
  p_opening_cash_amount numeric DEFAULT 5000000,
  p_closing_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_closing_date date := COALESCE(
    p_closing_date, (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  );
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders_total int;
  v_orders_completed int;
  v_orders_cancelled int;
  v_items_cancelled int;
  v_payments_count int;
  v_payments_total numeric;
  v_payments_cash numeric;
  v_payments_card numeric;
  v_payments_pay numeric;
  v_payments_bank_transfer numeric;
  v_service_count int;
  v_service_total numeric;
  v_low_stock_count int;
  v_delivery_cash_payout numeric(15,2);
  v_counted_cash numeric(15,2);
  v_expected_cash numeric(15,2);
  v_cash_variance numeric(15,2);
  v_existing_id uuid;
  v_existing_source text;
  v_new_id uuid;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RESTAURANT_REQUIRED';
  END IF;
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id, 'DAILY_CLOSING_FORBIDDEN'
  );
  IF v_closing_date > (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN
    RAISE EXCEPTION 'DAILY_CLOSING_DATE_INVALID';
  END IF;
  IF p_opening_cash_amount IS NULL OR p_opening_cash_amount < 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_OPENING_CASH_INVALID';
  END IF;
  IF jsonb_typeof(COALESCE(p_cash_denominations, '{}'::jsonb)) <> 'object'
     OR EXISTS (
       SELECT 1
       FROM jsonb_each_text(
         COALESCE(p_cash_denominations, '{}'::jsonb)
       ) entry
       WHERE entry.key NOT IN (
         '500000', '200000', '100000', '50000', '20000',
         '10000', '5000', '2000', '1000'
       )
          OR entry.value !~ '^[0-9]+$'
          OR entry.value::numeric > 10000
     ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_DENOMINATIONS_INVALID';
  END IF;

  SELECT COALESCE(sum(entry.key::numeric * entry.value::numeric), 0)
  INTO v_counted_cash
  FROM jsonb_each_text(
    COALESCE(p_cash_denominations, '{}'::jsonb)
  ) entry;

  v_day_start :=
    v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_day_end :=
    (v_closing_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  SELECT id, close_source
  INTO v_existing_id, v_existing_source
  FROM public.daily_closings
  WHERE restaurant_id = p_store_id
    AND closing_date = v_closing_date
  FOR UPDATE;

  IF FOUND AND v_existing_source <> 'scheduled' THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  SELECT count(*),
    count(*) FILTER (WHERE status = 'completed'),
    count(*) FILTER (WHERE status = 'cancelled')
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*)
  INTO v_items_cancelled
  FROM public.order_items item
  JOIN public.orders order_row ON order_row.id = item.order_id
  WHERE order_row.restaurant_id = p_store_id
    AND item.status = 'cancelled'
    AND order_row.created_at >= v_day_start
    AND order_row.created_at < v_day_end;

  SELECT
    count(*),
    COALESCE(sum(COALESCE(amount_portion, amount)), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) = 'cash'
    ), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) IN ('card', 'creditcard', 'atm')
    ), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) NOT IN (
        'cash', 'card', 'creditcard', 'atm', 'banktransfer'
      )
    ), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) = 'banktransfer'
    ), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash,
    v_payments_card, v_payments_pay, v_payments_bank_transfer
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = true
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*), COALESCE(sum(COALESCE(amount_portion, amount)), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = false
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_store_id
    AND is_active = true
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  SELECT COALESCE(sum(actual_grab_fee), 0)
  INTO v_delivery_cash_payout
  FROM public.direct_order_dispatches
  WHERE restaurant_id = p_store_id
    AND actual_grab_fee IS NOT NULL
    AND cash_paid_at >= v_day_start
    AND cash_paid_at < v_day_end;

  v_expected_cash :=
    p_opening_cash_amount + v_payments_cash - v_delivery_cash_payout;
  v_cash_variance := v_counted_cash - v_expected_cash;

  IF v_existing_id IS NULL THEN
    INSERT INTO public.daily_closings (
      restaurant_id, closing_date, closed_by, close_source,
      orders_total, orders_completed, orders_cancelled, items_cancelled,
      payments_count, payments_total, payments_cash, payments_card,
      payments_pay, payments_bank_transfer, service_count, service_total,
      low_stock_count, notes, opening_cash_amount, cash_denominations,
      delivery_cash_payout, expected_cash_amount, counted_cash_amount,
      cash_variance
    ) VALUES (
      p_store_id, v_closing_date, auth.uid(), 'manual',
      v_orders_total, v_orders_completed, v_orders_cancelled,
      v_items_cancelled, v_payments_count, v_payments_total,
      v_payments_cash, v_payments_card, v_payments_pay,
      v_payments_bank_transfer, v_service_count, v_service_total,
      v_low_stock_count, p_notes, p_opening_cash_amount,
      COALESCE(p_cash_denominations, '{}'::jsonb),
      v_delivery_cash_payout, v_expected_cash, v_counted_cash,
      v_cash_variance
    ) RETURNING id INTO v_new_id;
  ELSE
    UPDATE public.daily_closings
    SET closed_by = auth.uid(),
        close_source = 'manual',
        orders_total = v_orders_total,
        orders_completed = v_orders_completed,
        orders_cancelled = v_orders_cancelled,
        items_cancelled = v_items_cancelled,
        payments_count = v_payments_count,
        payments_total = v_payments_total,
        payments_cash = v_payments_cash,
        payments_card = v_payments_card,
        payments_pay = v_payments_pay,
        payments_bank_transfer = v_payments_bank_transfer,
        service_count = v_service_count,
        service_total = v_service_total,
        low_stock_count = v_low_stock_count,
        notes = p_notes,
        opening_cash_amount = p_opening_cash_amount,
        cash_denominations = COALESCE(p_cash_denominations, '{}'::jsonb),
        delivery_cash_payout = v_delivery_cash_payout,
        expected_cash_amount = v_expected_cash,
        counted_cash_amount = v_counted_cash,
        cash_variance = v_cash_variance,
        created_at = now()
    WHERE id = v_existing_id
    RETURNING id INTO v_new_id;
  END IF;

  INSERT INTO public.audit_logs(
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(),
    CASE WHEN v_existing_id IS NULL
      THEN 'create_daily_closing'
      ELSE 'reconcile_scheduled_daily_closing'
    END,
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'closing_date', v_closing_date,
      'payments_total', v_payments_total,
      'payments_cash', v_payments_cash,
      'payments_bank_transfer', v_payments_bank_transfer,
      'delivery_cash_payout', v_delivery_cash_payout,
      'opening_cash_amount', p_opening_cash_amount,
      'expected_cash_amount', v_expected_cash,
      'counted_cash_amount', v_counted_cash,
      'cash_variance', v_cash_variance,
      'cash_denominations', COALESCE(p_cash_denominations, '{}'::jsonb)
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_bank_transfer', v_payments_bank_transfer,
    'delivery_cash_payout', v_delivery_cash_payout,
    'opening_cash_amount', p_opening_cash_amount,
    'expected_cash_amount', v_expected_cash,
    'counted_cash_amount', v_counted_cash,
    'cash_variance', v_cash_variance
  );
END;
$$;

DROP FUNCTION IF EXISTS public.get_daily_closing_days(uuid, int);
CREATE FUNCTION public.get_daily_closing_days(
  p_store_id uuid,
  p_limit int DEFAULT 30
) RETURNS TABLE (
  closing_id uuid,
  closing_date date,
  closed_by_name text,
  orders_total int,
  orders_completed int,
  orders_cancelled int,
  items_cancelled int,
  payments_count int,
  payments_total numeric,
  payments_cash numeric,
  payments_card numeric,
  payments_pay numeric,
  payments_bank_transfer numeric,
  delivery_cash_payout numeric,
  opening_cash_amount numeric,
  expected_cash_amount numeric,
  counted_cash_amount numeric,
  cash_variance numeric,
  service_count int,
  service_total numeric,
  low_stock_count int,
  notes text,
  created_at timestamptz,
  close_source text,
  snapshot_payments_total numeric,
  ledger_payments_count int,
  ledger_payments_total numeric,
  ledger_payments_cash numeric,
  ledger_payments_card numeric,
  ledger_payments_pay numeric,
  ledger_payments_bank_transfer numeric,
  reconciliation_delta numeric,
  ledger_as_of timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id, 'DAILY_CLOSINGS_FORBIDDEN'
  );

  RETURN QUERY
  WITH business_days AS (
    SELECT (
      (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - day_offset
    )::date AS business_date
    FROM generate_series(0, v_limit - 1) AS days(day_offset)
  ), live_orders AS (
    SELECT
      (order_row.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
        AS business_date,
      count(*)::int AS orders_total,
      count(*) FILTER (WHERE order_row.status = 'completed')::int
        AS orders_completed,
      count(*) FILTER (WHERE order_row.status = 'cancelled')::int
        AS orders_cancelled
    FROM public.orders order_row
    JOIN business_days day_row
      ON day_row.business_date =
        (order_row.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE order_row.restaurant_id = p_store_id
    GROUP BY 1
  ), live_cancelled_items AS (
    SELECT
      (order_row.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
        AS business_date,
      count(*)::int AS items_cancelled
    FROM public.order_items item
    JOIN public.orders order_row ON order_row.id = item.order_id
    JOIN business_days day_row
      ON day_row.business_date =
        (order_row.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE order_row.restaurant_id = p_store_id
      AND item.status = 'cancelled'
    GROUP BY 1
  ), live_payments AS (
    SELECT
      (payment.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
        AS business_date,
      count(*) FILTER (WHERE payment.is_revenue)::int AS payments_count,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE payment.is_revenue
      ), 0) AS payments_total,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE payment.is_revenue AND lower(payment.method) = 'cash'
      ), 0) AS payments_cash,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE payment.is_revenue
          AND lower(payment.method) IN ('card', 'creditcard', 'atm')
      ), 0) AS payments_card,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE payment.is_revenue
          AND lower(payment.method) NOT IN (
            'cash', 'card', 'creditcard', 'atm', 'banktransfer'
          )
      ), 0) AS payments_pay,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE payment.is_revenue AND lower(payment.method) = 'banktransfer'
      ), 0) AS payments_bank_transfer,
      count(*) FILTER (WHERE NOT payment.is_revenue)::int AS service_count,
      COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)) FILTER (
        WHERE NOT payment.is_revenue
      ), 0) AS service_total
    FROM public.payments payment
    JOIN business_days day_row
      ON day_row.business_date =
        (payment.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE payment.restaurant_id = p_store_id
    GROUP BY 1
  ), live_delivery_cash_payouts AS (
    SELECT
      (dispatch.cash_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
        AS business_date,
      COALESCE(sum(dispatch.actual_grab_fee), 0)
        AS delivery_cash_payout
    FROM public.direct_order_dispatches dispatch
    JOIN business_days day_row
      ON day_row.business_date =
        (dispatch.cash_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE dispatch.restaurant_id = p_store_id
      AND dispatch.actual_grab_fee IS NOT NULL
      AND dispatch.cash_paid_at IS NOT NULL
    GROUP BY 1
  )
  SELECT
    closing.id,
    day_row.business_date,
    COALESCE(actor.full_name, CASE
      WHEN closing.close_source = 'scheduled' THEN 'Scheduled'
      ELSE ''
    END),
    CASE WHEN closing.close_source = 'manual'
      THEN closing.orders_total
      ELSE COALESCE(live_order.orders_total, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.orders_completed
      ELSE COALESCE(live_order.orders_completed, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.orders_cancelled
      ELSE COALESCE(live_order.orders_cancelled, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.items_cancelled
      ELSE COALESCE(cancelled_item.items_cancelled, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_count
      ELSE COALESCE(ledger.payments_count, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_total
      ELSE COALESCE(ledger.payments_total, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_cash
      ELSE COALESCE(ledger.payments_cash, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_card
      ELSE COALESCE(ledger.payments_card, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_pay
      ELSE COALESCE(ledger.payments_pay, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.payments_bank_transfer
      ELSE COALESCE(ledger.payments_bank_transfer, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.delivery_cash_payout
      ELSE COALESCE(payout.delivery_cash_payout, 0)
    END,
    COALESCE(closing.opening_cash_amount, 0),
    COALESCE(closing.expected_cash_amount, 0),
    COALESCE(closing.counted_cash_amount, 0),
    COALESCE(closing.cash_variance, 0),
    CASE WHEN closing.close_source = 'manual'
      THEN closing.service_count
      ELSE COALESCE(ledger.service_count, 0)
    END,
    CASE WHEN closing.close_source = 'manual'
      THEN closing.service_total
      ELSE COALESCE(ledger.service_total, 0)
    END,
    COALESCE(closing.low_stock_count, 0),
    closing.notes,
    closing.created_at,
    closing.close_source,
    closing.payments_total,
    COALESCE(ledger.payments_count, 0),
    COALESCE(ledger.payments_total, 0),
    COALESCE(ledger.payments_cash, 0),
    COALESCE(ledger.payments_card, 0),
    COALESCE(ledger.payments_pay, 0),
    COALESCE(ledger.payments_bank_transfer, 0),
    CASE WHEN closing.id IS NULL THEN 0
      ELSE COALESCE(ledger.payments_total, 0) - closing.payments_total
    END,
    now()
  FROM business_days day_row
  LEFT JOIN public.daily_closings closing
    ON closing.restaurant_id = p_store_id
   AND closing.closing_date = day_row.business_date
  LEFT JOIN public.users actor ON actor.auth_id = closing.closed_by
  LEFT JOIN live_orders live_order
    ON live_order.business_date = day_row.business_date
  LEFT JOIN live_cancelled_items cancelled_item
    ON cancelled_item.business_date = day_row.business_date
  LEFT JOIN live_payments ledger
    ON ledger.business_date = day_row.business_date
  LEFT JOIN live_delivery_cash_payouts payout
    ON payout.business_date = day_row.business_date
  ORDER BY day_row.business_date DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_daily_closing(
  uuid, text, jsonb, numeric, date
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_daily_closing(
  uuid, text, jsonb, numeric, date
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_daily_closing_days(uuid, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_days(uuid, int)
  TO authenticated, service_role;

DO $$
DECLARE
  v_result text;
  v_create_definition text;
  v_days_definition text;
BEGIN
  SELECT pg_catalog.pg_get_function_result(
    'public.get_daily_closing_days(uuid,integer)'::regprocedure
  ) INTO v_result;
  SELECT pg_catalog.pg_get_functiondef(
    'public.create_daily_closing(uuid,text,jsonb,numeric,date)'::regprocedure
  ) INTO v_create_definition;
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_daily_closing_days(uuid,integer)'::regprocedure
  ) INTO v_days_definition;

  IF position('ledger_payments_total numeric' IN lower(v_result)) = 0
     OR position('snapshot_payments_total numeric' IN lower(v_result)) = 0
     OR position('reconciliation_delta numeric' IN lower(v_result)) = 0
     OR position('ledger_as_of timestamp with time zone' IN lower(v_result)) = 0
     OR position('payments_bank_transfer numeric' IN lower(v_result)) = 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RECONCILIATION_RESULT_MISSING';
  END IF;

  IF position('payments_bank_transfer = v_payments_bank_transfer'
       IN v_create_definition) = 0
     OR position('lower(method) = ''banktransfer'''
       IN v_create_definition) = 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_BANK_TRANSFER_SNAPSHOT_MISSING';
  END IF;

  IF position('closing.close_source = ''manual''' IN v_days_definition) = 0
     OR position('ledger.payments_total' IN v_days_definition) = 0
     OR position('ledger.payments_total, 0) - closing.payments_total'
       IN v_days_definition) = 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_LIVE_SNAPSHOT_SPLIT_MISSING';
  END IF;
END;
$$;

COMMIT;
