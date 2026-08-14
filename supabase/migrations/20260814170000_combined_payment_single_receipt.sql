BEGIN;

-- production-gate: self-verifying
-- A combined tender keeps per-order payments for accounting, but owns one
-- customer-facing receipt print job for the entire payment group.

ALTER TABLE public.print_jobs
  ADD COLUMN IF NOT EXISTS combined_payment_group_id uuid
  REFERENCES public.combined_payment_groups(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_print_jobs_combined_payment_group
  ON public.print_jobs(combined_payment_group_id, created_at DESC)
  WHERE combined_payment_group_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS print_jobs_combined_receipt_idempotent
  ON public.print_jobs(
    combined_payment_group_id, copy_type, batch_no, destination_id
  )
  WHERE combined_payment_group_id IS NOT NULL
    AND destination_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS print_jobs_combined_receipt_no_destination
  ON public.print_jobs(combined_payment_group_id, copy_type, batch_no)
  WHERE combined_payment_group_id IS NOT NULL
    AND destination_id IS NULL;

CREATE OR REPLACE FUNCTION public.enqueue_combined_receipt_print_job(
  p_group_id uuid,
  p_received_amount numeric DEFAULT NULL,
  p_reprint boolean DEFAULT false
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_group public.combined_payment_groups%ROWTYPE;
  v_job public.print_jobs%ROWTYPE;
  v_primary_order_id uuid;
  v_linked_order_count integer;
  v_destination_id uuid;
  v_batch_no integer := 1;
  v_status text := 'pending';
  v_error text;
  v_table_numbers text;
  v_items jsonb := '[]'::jsonb;
  v_profile record;
  v_address_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(15,2) := 0;
  v_discount numeric(15,2) := 0;
  v_vat numeric(15,2) := 0;
  v_received numeric(15,2);
  v_change numeric(15,2);
  v_cashier text := 'CASHIER';
  v_receipt_number text;
  v_payload jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PRINT_FORBIDDEN';
  END IF;

  SELECT * INTO v_group
  FROM public.combined_payment_groups
  WHERE id = p_group_id
  FOR UPDATE;

  IF NOT FOUND OR v_group.status <> 'completed' THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PAYMENT_REQUIRED';
  END IF;

  IF NOT public.is_super_admin() AND NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = v_group.restaurant_id
  ) THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PRINT_FORBIDDEN';
  END IF;

  SELECT count(DISTINCT payment.order_id)::integer
  INTO v_linked_order_count
  FROM public.payments payment
  WHERE payment.combined_payment_group_id = v_group.id
    AND payment.restaurant_id = v_group.restaurant_id;

  SELECT payment.order_id
  INTO v_primary_order_id
  FROM public.payments payment
  WHERE payment.combined_payment_group_id = v_group.id
    AND payment.restaurant_id = v_group.restaurant_id
  ORDER BY payment.order_id
  LIMIT 1;

  IF v_primary_order_id IS NULL
     OR v_linked_order_count <> v_group.order_count THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_ORDER_LINK_MISMATCH';
  END IF;

  IF NOT COALESCE(p_reprint, false) THEN
    SELECT * INTO v_job
    FROM public.print_jobs
    WHERE combined_payment_group_id = v_group.id
      AND copy_type = 'receipt'
      AND batch_no = 1
    ORDER BY created_at DESC, id DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN v_job;
    END IF;
  ELSE
    SELECT COALESCE(max(batch_no), 0) + 1
    INTO v_batch_no
    FROM public.print_jobs
    WHERE combined_payment_group_id = v_group.id
      AND copy_type = 'receipt';
  END IF;

  SELECT string_agg(DISTINCT COALESCE(table_row.table_number, 'STAFF'), ', '
    ORDER BY COALESCE(table_row.table_number, 'STAFF'))
  INTO v_table_numbers
  FROM public.payments payment
  JOIN public.orders order_row ON order_row.id = payment.order_id
  LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
  WHERE payment.combined_payment_group_id = v_group.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'label', '[' || source.table_number || '] ' || source.label,
    'quantity', source.quantity,
    'unit_price', source.unit_price,
    'is_service_item', source.is_service_item
  ) ORDER BY source.table_number, source.created_at, source.id), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT DISTINCT ON (item.id)
      item.id,
      item.created_at,
      COALESCE(table_row.table_number, 'STAFF') AS table_number,
      COALESCE(NULLIF(item.label, ''), NULLIF(item.display_name, ''), 'Item')
        AS label,
      item.quantity,
      item.unit_price,
      COALESCE(item.is_service_item, false) AS is_service_item
    FROM public.payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_row.id
    WHERE payment.combined_payment_group_id = v_group.id
      AND item.status <> 'cancelled'
    ORDER BY item.id
  ) source;

  SELECT
    ROUND(COALESCE(sum(item.unit_price * item.quantity)
      FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2),
    ROUND(COALESCE(sum(item.vat_amount)
      FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2)
  INTO v_subtotal, v_vat
  FROM public.order_items item
  WHERE item.order_id IN (
    SELECT payment.order_id
    FROM public.payments payment
    WHERE payment.combined_payment_group_id = v_group.id
  ) AND item.status <> 'cancelled';

  SELECT ROUND(COALESCE(sum(discount.discount_amount), 0), 2)
  INTO v_discount
  FROM public.order_discounts discount
  WHERE discount.order_id IN (
    SELECT payment.order_id
    FROM public.payments payment
    WHERE payment.combined_payment_group_id = v_group.id
  ) AND discount.status IN ('active', 'consumed');

  SELECT
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN 'BUNSIK CLUB' ELSE COALESCE(brand.name, restaurant.name) END
      AS brand_name,
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN 'CÔNG TY TNHH AKJ INTERNATIONAL' ELSE tax_entity.name END
      AS legal_name,
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN '0318453298' ELSE NULLIF(tax_entity.tax_code, 'PLACEHOLDER_DEV_000')
      END AS tax_code,
    restaurant.address
  INTO v_profile
  FROM public.restaurants restaurant
  LEFT JOIN public.brands brand ON brand.id = restaurant.brand_id
  LEFT JOIN public.tax_entity tax_entity
    ON tax_entity.id = restaurant.tax_entity_id
  WHERE restaurant.id = v_group.restaurant_id;

  IF lower(COALESCE(v_profile.brand_name, '')) LIKE '%bunsik%' THEN
    v_address_lines := jsonb_build_array(
      '69/1A2 Nguyễn Gia Trí',
      'Phường Thạnh Mỹ Tây',
      'Thành phố Hồ Chí Minh'
    );
  ELSIF NULLIF(v_profile.address, '') IS NOT NULL THEN
    v_address_lines := jsonb_build_array(v_profile.address);
  END IF;

  SELECT COALESCE(NULLIF(user_row.fixed_account_code, ''),
    NULLIF(user_row.full_name, ''), 'CASHIER')
  INTO v_cashier
  FROM public.users user_row
  WHERE user_row.auth_id = v_group.processed_by
  LIMIT 1;

  v_received := ROUND(COALESCE(p_received_amount, v_group.total_amount), 2);
  IF v_received < v_group.total_amount THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_RECEIVED_AMOUNT_INSUFFICIENT';
  END IF;
  v_change := ROUND(v_received - v_group.total_amount, 2);
  v_receipt_number := 'BC-' ||
    to_char(v_group.completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD') ||
    '-' || lpad((('x' || substr(md5(v_group.id::text), 1, 8))::bit(32)::bigint
      % 1000000)::text, 6, '0');

  SELECT id INTO v_destination_id
  FROM public.printer_destinations
  WHERE restaurant_id = v_group.restaurant_id
    AND purpose = 'receipt'
    AND is_active = true
  ORDER BY created_at, id
  LIMIT 1;

  IF v_destination_id IS NULL THEN
    v_status := 'failed';
    v_error := 'NO_DESTINATION';
  END IF;

  v_payload := jsonb_build_object(
    'ticket', 'receipt',
    'is_combined', true,
    'combined_payment_group_id', v_group.id,
    'restaurant_name', v_profile.brand_name,
    'legal_name', v_profile.legal_name,
    'tax_code', v_profile.tax_code,
    'address_lines', v_address_lines,
    'table_number', v_table_numbers,
    'ticket_code', substring(v_group.id::text from 1 for 8),
    'batch_no', v_batch_no,
    'printed_reason', CASE WHEN COALESCE(p_reprint, false)
      THEN 'reprint' ELSE 'payment' END,
    'at', to_char(v_group.completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
      'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'),
    'items', v_items,
    'total_amount', v_group.total_amount,
    'payment_method', upper(v_group.method),
    'is_service', false,
    'combined_receipt_number', v_receipt_number,
    'combined_cashier_code', COALESCE(v_cashier, 'CASHIER'),
    'combined_subtotal_amount', v_subtotal,
    'combined_discount_amount', v_discount,
    'combined_vat_amount', v_vat,
    'combined_received_amount', v_received,
    'combined_change_amount', v_change
  );

  INSERT INTO public.print_jobs (
    restaurant_id, order_id, combined_payment_group_id, copy_type, batch_no,
    destination_id, payload, status, last_error
  ) VALUES (
    v_group.restaurant_id, v_primary_order_id, v_group.id, 'receipt',
    v_batch_no, v_destination_id, v_payload, v_status, v_error
  ) RETURNING * INTO v_job;

  INSERT INTO public.audit_logs (
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(), 'enqueue_combined_receipt_print_job', 'print_jobs', v_job.id,
    jsonb_build_object(
      'store_id', v_group.restaurant_id,
      'combined_payment_group_id', v_group.id,
      'order_count', v_group.order_count,
      'batch_no', v_batch_no,
      'reprint', COALESCE(p_reprint, false),
      'status', v_status,
      'updated_at_utc', now()
    )
  );

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_combined_receipt_print_job(
  uuid, numeric, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_combined_receipt_print_job(
  uuid, numeric, boolean
) TO authenticated, service_role;

DO $$
DECLARE
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_missing
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'print_jobs'
    AND column_name = 'combined_payment_group_id';
  IF v_missing <> 1 THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PRINT_LINK_VERIFY_FAILED: %', v_missing;
  END IF;

  SELECT count(*) INTO v_missing
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
  WHERE namespace.nspname = 'public'
    AND procedure.proname = 'enqueue_combined_receipt_print_job'
    AND pg_get_function_identity_arguments(procedure.oid) =
      'p_group_id uuid, p_received_amount numeric, p_reprint boolean';
  IF v_missing <> 1 THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PRINT_RPC_VERIFY_FAILED: %', v_missing;
  END IF;
END;
$$;

COMMIT;
