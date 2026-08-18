BEGIN;

-- production-gate: self-verifying
-- A combined tender is one discoverable ledger transaction. Its per-order
-- payment rows remain implementation details exposed only as allocations.

CREATE OR REPLACE FUNCTION public.get_receipt_ledger(
  p_business_date date,
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
  v_business_date date := p_business_date;
  v_start timestamptz :=
    v_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end timestamptz :=
    (v_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_query text := NULLIF(btrim(COALESCE(p_query, '')), '');
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
  v_result jsonb;
BEGIN
  IF v_business_date IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_BUSINESS_DATE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_STORE_REQUIRED';
  END IF;

  IF p_store_id IS NOT NULL
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  WITH scoped_payments AS (
    SELECT
      payment.id,
      payment.order_id,
      payment.restaurant_id AS store_id,
      payment.combined_payment_group_id,
      CASE
        WHEN payment.combined_payment_group_id IS NULL
          THEN 'order:' || payment.order_id::text
        ELSE 'combined:' || payment.combined_payment_group_id::text
      END AS ledger_key,
      COALESCE(payment.amount_portion, payment.amount) AS amount,
      payment.method,
      COALESCE(payment_group.completed_at, payment.created_at) AS sold_at,
      COALESCE(
        NULLIF(user_row.fixed_account_code, ''),
        NULLIF(user_row.full_name, ''),
        'CASHIER'
      ) AS cashier_name
    FROM public.payments payment
    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    LEFT JOIN public.users user_row
      ON user_row.auth_id = payment.processed_by
    WHERE payment.is_revenue = true
      AND COALESCE(payment_group.completed_at, payment.created_at) >= v_start
      AND COALESCE(payment_group.completed_at, payment.created_at) < v_end
      AND (p_store_id IS NULL OR payment.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = payment.restaurant_id
        )
      )
  ),
  payment_adjustment_totals AS (
    SELECT
      payment.ledger_key,
      ROUND(COALESCE(sum(adjustment.amount), 0), 2) AS adjusted_amount
    FROM public.payment_adjustments adjustment
    JOIN scoped_payments payment ON payment.id = adjustment.payment_id
    GROUP BY payment.ledger_key
  ),
  pos_payment_groups AS (
    SELECT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id,
      max(payment.sold_at) AS sold_at,
      (array_agg(DISTINCT payment.order_id ORDER BY payment.order_id))[1]
        AS primary_order_id,
      array_agg(DISTINCT payment.order_id ORDER BY payment.order_id)
        AS order_ids,
      ROUND(sum(payment.amount), 2) AS gross_amount,
      (array_agg(
        payment.cashier_name
        ORDER BY payment.sold_at DESC, payment.id DESC
      ))[1] AS cashier_name
    FROM scoped_payments payment
    GROUP BY
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id
  ),
  pos_payment_methods AS (
    SELECT
      payment.ledger_key,
      payment.method,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    GROUP BY payment.ledger_key, payment.method
  ),
  pos_payment_summaries AS (
    SELECT
      payment.ledger_key,
      jsonb_agg(jsonb_build_object(
        'method', payment.method,
        'amount', payment.amount
      ) ORDER BY payment.method) AS payments
    FROM pos_payment_methods payment
    GROUP BY payment.ledger_key
  ),
  pos_allocations AS (
    SELECT
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY') AS table_number,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    GROUP BY
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY')
  ),
  pos_allocation_summaries AS (
    SELECT
      allocation.ledger_key,
      string_agg(
        allocation.table_number,
        ', ' ORDER BY allocation.table_number, allocation.order_id
      ) AS table_number,
      jsonb_agg(jsonb_build_object(
        'order_id', allocation.order_id,
        'table_number', allocation.table_number,
        'amount', allocation.amount
      ) ORDER BY allocation.table_number, allocation.order_id) AS allocations
    FROM pos_allocations allocation
    GROUP BY allocation.ledger_key
  ),
  pos_order_keys AS (
    SELECT DISTINCT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.order_id,
      payment.store_id
    FROM scoped_payments payment
  ),
  pos_order_items AS (
    SELECT
      order_key.ledger_key,
      jsonb_agg(jsonb_build_object(
        'order_id', item.order_id,
        'table_number', COALESCE(table_row.table_number, 'TAKEAWAY'),
        'name', CASE
          WHEN order_key.combined_payment_group_id IS NULL THEN COALESCE(
            NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
          )
          ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' ||
            COALESCE(
              NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
            )
        END,
        'quantity', item.quantity,
        'unit_price', item.unit_price
      ) ORDER BY
        COALESCE(table_row.table_number, 'TAKEAWAY'),
        item.created_at,
        item.id
      ) AS items
    FROM pos_order_keys order_key
    JOIN public.orders order_row ON order_row.id = order_key.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_key.order_id
    WHERE item.status <> 'cancelled'
    GROUP BY order_key.ledger_key
  ),
  all_receipts AS (
    SELECT
      COALESCE(
        receipt.id::text,
        COALESCE(
          payment_group.combined_payment_group_id,
          payment_group.primary_order_id
        )::text
      ) AS receipt_id,
      COALESCE(
        receipt.receipt_number,
        CASE
          WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
            'BC-' || to_char(
              payment_group.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
              'YYYYMMDD'
            ) || '-' || lpad(((
              ('x' || substr(md5(
                payment_group.combined_payment_group_id::text
              ), 1, 8))::bit(32)::bigint % 1000000
            )::text), 6, '0')
          ELSE 'POS-' || upper(substr(replace(
            payment_group.primary_order_id::text, '-', ''
          ), 1, 10))
        END
      ) AS receipt_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN payment_group.primary_order_id
        ELSE NULL::uuid
      END AS order_id,
      payment_group.combined_payment_group_id,
      to_jsonb(payment_group.order_ids) AS order_ids,
      payment_group.store_id,
      restaurant.name AS store_name,
      payment_group.sold_at,
      allocation.table_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN primary_order.sales_channel
        ELSE 'combined'
      END AS sales_channel,
      payment_group.cashier_name,
      payment_summary.payments,
      allocation.allocations,
      COALESCE(order_items.items, '[]'::jsonb) AS items,
      payment_group.gross_amount,
      LEAST(
        payment_group.gross_amount,
        COALESCE(adjustment.adjusted_amount, 0)
      ) AS adjusted_amount,
      GREATEST(
        payment_group.gross_amount - COALESCE(adjustment.adjusted_amount, 0),
        0
      ) AS net_amount,
      CASE
        WHEN COALESCE(adjustment.adjusted_amount, 0) >=
             payment_group.gross_amount THEN 'refunded'
        WHEN COALESCE(adjustment.adjusted_amount, 0) > 0
          THEN 'partially_refunded'
        ELSE 'paid'
      END AS receipt_status,
      'pos'::text AS receipt_source,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN 'single'
        ELSE 'combined'
      END AS receipt_scope,
      true AS printable,
      receipt.id IS NOT NULL AS digital_receipt_ready,
      CASE
        WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
          COALESCE(
            NULLIF(receipt.snapshot->>'received_amount', '')::numeric,
            payment_group.gross_amount
          )
        ELSE payment_group.gross_amount
      END AS received_amount
    FROM pos_payment_groups payment_group
    JOIN public.orders primary_order
      ON primary_order.id = payment_group.primary_order_id
    JOIN public.restaurants restaurant
      ON restaurant.id = payment_group.store_id
    JOIN pos_payment_summaries payment_summary
      ON payment_summary.ledger_key = payment_group.ledger_key
    JOIN pos_allocation_summaries allocation
      ON allocation.ledger_key = payment_group.ledger_key
    LEFT JOIN public.digital_receipts receipt ON (
      payment_group.combined_payment_group_id IS NOT NULL
      AND receipt.combined_payment_group_id =
        payment_group.combined_payment_group_id
      AND receipt.order_id IS NULL
    ) OR (
      payment_group.combined_payment_group_id IS NULL
      AND receipt.order_id = payment_group.primary_order_id
    )
    LEFT JOIN payment_adjustment_totals adjustment
      ON adjustment.ledger_key = payment_group.ledger_key
    LEFT JOIN pos_order_items order_items
      ON order_items.ledger_key = payment_group.ledger_key

    UNION ALL

    SELECT
      external.id::text,
      COALESCE(NULLIF(external.external_order_id, ''), external.id::text),
      NULL::uuid,
      NULL::uuid,
      '[]'::jsonb,
      external.restaurant_id,
      restaurant.name,
      COALESCE(external.completed_at, external.created_at),
      '-'::text,
      external.sales_channel,
      external.source_system,
      jsonb_build_array(jsonb_build_object(
        'method', external.source_system,
        'amount', external.net_amount
      )),
      '[]'::jsonb,
      '[]'::jsonb,
      external.gross_amount,
      GREATEST(external.gross_amount - external.net_amount, 0),
      external.net_amount,
      CASE external.order_status
        WHEN 'completed' THEN 'paid'
        WHEN 'partially_refunded' THEN 'partially_refunded'
        ELSE 'refunded'
      END,
      'external'::text,
      'external'::text,
      false,
      false,
      external.gross_amount
    FROM public.external_sales external
    JOIN public.restaurants restaurant
      ON restaurant.id = external.restaurant_id
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
        OR COALESCE(receipt.combined_payment_group_id::text, '')
          ILIKE '%' || v_query || '%'
        OR receipt.order_ids::text ILIKE '%' || v_query || '%'
        OR receipt.allocations::text ILIKE '%' || v_query || '%'
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
    'receipts', COALESCE(
      (SELECT jsonb_agg(to_jsonb(page)) FROM page),
      '[]'::jsonb
    ),
    'has_more',
      (SELECT count(*) FROM filtered_receipts) > v_offset + v_limit
  ) INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) IS 'Role-scoped receipt ledger with one row per combined tender and order allocations in its detail.';

DO $$
DECLARE
  v_function regprocedure :=
    'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(procedure_row.oid)
  INTO v_definition
  FROM pg_catalog.pg_proc procedure_row
  WHERE procedure_row.oid = v_function;

  IF pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_function, 'EXECUTE'
     )
     OR position('combined_payment_group_id' IN v_definition) = 0
     OR position('pos_allocation_summaries AS' IN v_definition) = 0
     OR position('receipt_scope' IN v_definition) = 0
     OR position('payment_group.primary_order_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_LEDGER_GROUPING_VERIFY_FAILED';
  END IF;
END;
$$;

COMMIT;
