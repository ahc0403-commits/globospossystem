-- Read-only, role-scoped ledger for today's HCM business date.
-- POS split payments collapse to one receipt row per order. External delivery
-- receipts remain visible but are not printable by the POS print queue.

BEGIN;

-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.get_today_receipt_ledger(
  p_store_id uuid DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_business_date date := (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_start timestamptz := v_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end timestamptz := (v_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_query text := NULLIF(btrim(COALESCE(p_query, '')), '');
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
  v_result jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'TODAY_RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'TODAY_RECEIPT_LEDGER_STORE_REQUIRED';
  END IF;

  IF p_store_id IS NOT NULL
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'TODAY_RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  WITH payment_adjustment_totals AS (
    SELECT
      adjustment.order_id,
      ROUND(COALESCE(sum(adjustment.amount), 0), 2) AS adjusted_amount
    FROM public.payment_adjustments adjustment
    JOIN public.payments adjusted_payment
      ON adjusted_payment.id = adjustment.payment_id
     AND adjusted_payment.is_revenue = true
    GROUP BY adjustment.order_id
  ),
  pos_payment_groups AS (
    SELECT
      payment.order_id,
      payment.restaurant_id AS store_id,
      max(payment.created_at) AS sold_at,
      ROUND(sum(COALESCE(payment.amount_portion, payment.amount)), 2) AS gross_amount,
      jsonb_agg(
        jsonb_build_object(
          'id', payment.id,
          'method', payment.method,
          'amount', ROUND(COALESCE(payment.amount_portion, payment.amount), 2)
        ) ORDER BY payment.created_at, payment.id
      ) AS payments,
      (array_agg(
        COALESCE(NULLIF(user_row.fixed_account_code, ''),
          NULLIF(user_row.full_name, ''), 'CASHIER')
        ORDER BY payment.created_at DESC, payment.id DESC
      ))[1] AS cashier_name
    FROM public.payments payment
    LEFT JOIN public.users user_row ON user_row.auth_id = payment.processed_by
    WHERE payment.is_revenue = true
      AND payment.created_at >= v_start
      AND payment.created_at < v_end
      AND (p_store_id IS NULL OR payment.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = payment.restaurant_id
        )
      )
    GROUP BY payment.order_id, payment.restaurant_id
  ),
  all_receipts AS (
    SELECT
      COALESCE(receipt.id::text, payment_group.order_id::text) AS receipt_id,
      COALESCE(receipt.receipt_number,
        'POS-' || upper(substr(replace(payment_group.order_id::text, '-', ''), 1, 10))) AS receipt_number,
      payment_group.order_id,
      payment_group.store_id,
      restaurant.name AS store_name,
      payment_group.sold_at,
      COALESCE(table_row.table_number, 'TAKEAWAY') AS table_number,
      orders.sales_channel,
      payment_group.cashier_name,
      payment_group.payments,
      payment_group.gross_amount,
      LEAST(payment_group.gross_amount,
        COALESCE(adjustment.adjusted_amount, 0)) AS adjusted_amount,
      GREATEST(payment_group.gross_amount -
        COALESCE(adjustment.adjusted_amount, 0), 0) AS net_amount,
      CASE
        WHEN COALESCE(adjustment.adjusted_amount, 0) >= payment_group.gross_amount
          THEN 'refunded'
        WHEN COALESCE(adjustment.adjusted_amount, 0) > 0
          THEN 'partially_refunded'
        ELSE 'paid'
      END AS receipt_status,
      'pos'::text AS receipt_source,
      true AS printable,
      receipt.id IS NOT NULL AS digital_receipt_ready
    FROM pos_payment_groups payment_group
    JOIN public.orders orders ON orders.id = payment_group.order_id
    JOIN public.restaurants restaurant ON restaurant.id = payment_group.store_id
    LEFT JOIN public.tables table_row ON table_row.id = orders.table_id
    LEFT JOIN public.digital_receipts receipt ON receipt.order_id = payment_group.order_id
    LEFT JOIN payment_adjustment_totals adjustment
      ON adjustment.order_id = payment_group.order_id

    UNION ALL

    SELECT
      external.id::text,
      COALESCE(NULLIF(external.external_order_id, ''), external.id::text),
      NULL::uuid,
      external.restaurant_id,
      restaurant.name,
      COALESCE(external.completed_at, external.created_at),
      '-'::text,
      external.sales_channel,
      external.source_system,
      jsonb_build_array(jsonb_build_object(
        'id', external.id,
        'method', external.source_system,
        'amount', external.net_amount
      )),
      external.gross_amount,
      GREATEST(external.gross_amount - external.net_amount, 0),
      external.net_amount,
      CASE external.order_status
        WHEN 'completed' THEN 'paid'
        WHEN 'partially_refunded' THEN 'partially_refunded'
        ELSE 'refunded'
      END,
      'external'::text,
      false,
      false
    FROM public.external_sales external
    JOIN public.restaurants restaurant ON restaurant.id = external.restaurant_id
    WHERE external.is_revenue = true
      AND COALESCE(external.completed_at, external.created_at) >= v_start
      AND COALESCE(external.completed_at, external.created_at) < v_end
      AND (p_store_id IS NULL OR external.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = external.restaurant_id
        )
      )
  ),
  filtered_receipts AS (
    SELECT *
    FROM all_receipts receipt
    WHERE (v_status IS NULL OR receipt.receipt_status = v_status)
      AND (
        v_query IS NULL
        OR receipt.receipt_number ILIKE '%' || v_query || '%'
        OR receipt.store_name ILIKE '%' || v_query || '%'
        OR receipt.table_number ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.order_id::text, '') ILIKE '%' || v_query || '%'
      )
  ),
  page AS (
    SELECT *
    FROM filtered_receipts
    ORDER BY sold_at DESC, receipt_id DESC
    LIMIT v_limit OFFSET v_offset
  ),
  summary AS (
    SELECT
      count(*)::integer AS receipt_count,
      ROUND(COALESCE(sum(gross_amount), 0), 2) AS gross_amount,
      ROUND(COALESCE(sum(adjusted_amount), 0), 2) AS adjusted_amount,
      ROUND(COALESCE(sum(net_amount), 0), 2) AS net_amount
    FROM all_receipts
  )
  SELECT jsonb_build_object(
    'business_date', v_business_date,
    'generated_at', statement_timestamp(),
    'summary', jsonb_build_object(
      'receipt_count', summary.receipt_count,
      'gross_amount', summary.gross_amount,
      'adjusted_amount', summary.adjusted_amount,
      'net_amount', summary.net_amount
    ),
    'receipts', COALESCE((SELECT jsonb_agg(to_jsonb(page)) FROM page), '[]'::jsonb),
    'has_more', (SELECT count(*) FROM filtered_receipts) > v_offset + v_limit
  ) INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_today_receipt_ledger(
  uuid, text, text, integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_today_receipt_ledger(
  uuid, text, text, integer, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_today_receipt_ledger(
  uuid, text, text, integer, integer
) IS 'Role-scoped, read-only HCM current-business-day receipt ledger. POS rows aggregate split payments by order.';

DO $$
DECLARE
  v_function regprocedure :=
    'public.get_today_receipt_ledger(uuid,text,text,integer,integer)'::regprocedure;
  v_security_definer boolean;
  v_config text[];
BEGIN
  SELECT procedure_row.prosecdef, procedure_row.proconfig
  INTO v_security_definer, v_config
  FROM pg_catalog.pg_proc procedure_row
  WHERE procedure_row.oid = v_function;

  IF v_security_definer IS DISTINCT FROM true
     OR NOT COALESCE(v_config, ARRAY[]::text[]) @>
       ARRAY['search_path=public, auth']::text[]
     OR pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_function, 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'service_role', v_function, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'TODAY_RECEIPT_LEDGER_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
