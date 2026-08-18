BEGIN;

-- production-gate: self-verifying
-- Keep per-order payments and accounting, but expose exactly one customer
-- receipt snapshot for each completed combined-payment group. The same
-- snapshot repairs the paper print payload and backs the digital receipt QR.

ALTER TABLE public.digital_receipts
  ALTER COLUMN order_id DROP NOT NULL;

ALTER TABLE public.digital_receipts
  DROP CONSTRAINT IF EXISTS digital_receipts_customer_anchor_check;
ALTER TABLE public.digital_receipts
  ADD CONSTRAINT digital_receipts_customer_anchor_check CHECK (
    order_id IS NOT NULL OR combined_payment_group_id IS NOT NULL
  );

CREATE UNIQUE INDEX IF NOT EXISTS digital_receipts_combined_group_canonical
  ON public.digital_receipts(combined_payment_group_id)
  WHERE order_id IS NULL AND combined_payment_group_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.build_combined_customer_receipt_snapshot(
  p_group_id uuid,
  p_received_amount numeric DEFAULT NULL,
  p_change_amount numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_group public.combined_payment_groups%ROWTYPE;
  v_primary_order_id uuid;
  v_linked_order_count integer;
  v_order_ids jsonb := '[]'::jsonb;
  v_table_numbers text;
  v_items jsonb := '[]'::jsonb;
  v_subtotal numeric(15,2) := 0;
  v_discount numeric(15,2) := 0;
  v_vat numeric(15,2) := 0;
  v_service_charge numeric(15,2) := 0;
  v_received numeric(15,2);
  v_change numeric(15,2);
  v_cashier text := 'CASHIER';
  v_receipt_number text;
  v_profile record;
  v_address_lines jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_group
  FROM public.combined_payment_groups
  WHERE id = p_group_id
    AND status = 'completed';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_PAYMENT_REQUIRED';
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

  SELECT COALESCE(jsonb_agg(link.order_id ORDER BY link.order_id), '[]'::jsonb)
  INTO v_order_ids
  FROM (
    SELECT DISTINCT payment.order_id
    FROM public.payments payment
    WHERE payment.combined_payment_group_id = v_group.id
      AND payment.restaurant_id = v_group.restaurant_id
  ) link;

  SELECT string_agg(
    DISTINCT COALESCE(table_row.table_number, 'STAFF'), ', '
    ORDER BY COALESCE(table_row.table_number, 'STAFF')
  )
  INTO v_table_numbers
  FROM public.payments payment
  JOIN public.orders order_row ON order_row.id = payment.order_id
  LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
  WHERE payment.combined_payment_group_id = v_group.id
    AND payment.restaurant_id = v_group.restaurant_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', source.id,
    'order_id', source.order_id,
    'menu_item_id', source.menu_item_id,
    'table_number', source.table_number,
    'label', '[' || source.table_number || '] ' || source.label_vi,
    'quantity', source.quantity,
    'unit_price', source.unit_price,
    'line_total', ROUND(source.unit_price * source.quantity, 2),
    'paying_amount_inc_tax', source.paying_amount_inc_tax,
    'vat_amount', source.vat_amount,
    'item_type', source.item_type,
    'is_service_item', source.is_service_item
  ) ORDER BY source.table_number, source.created_at, source.id), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT DISTINCT ON (item.id)
      item.id,
      item.order_id,
      item.created_at,
      COALESCE(item.menu_item_id, item.menu_item_id_snapshot) AS menu_item_id,
      COALESCE(table_row.table_number, 'STAFF') AS table_number,
      CASE
        WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL
             AND btrim(menu.name_vi) !~ '[가-힣]'
          THEN btrim(menu.name_vi)
        ELSE 'Món'
      END AS label_vi,
      item.quantity,
      item.unit_price,
      item.paying_amount_inc_tax,
      COALESCE(item.vat_amount, 0) AS vat_amount,
      item.item_type,
      COALESCE(item.is_service_item, false) AS is_service_item
    FROM public.payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_row.id
    LEFT JOIN public.menu_items menu
      ON menu.id = COALESCE(item.menu_item_id, item.menu_item_id_snapshot)
     AND menu.restaurant_id = v_group.restaurant_id
    WHERE payment.combined_payment_group_id = v_group.id
      AND payment.restaurant_id = v_group.restaurant_id
      AND item.status <> 'cancelled'
    ORDER BY item.id
  ) source;

  SELECT
    ROUND(COALESCE(sum(item.unit_price * item.quantity)
      FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2),
    ROUND(COALESCE(sum(item.vat_amount)
      FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2),
    ROUND(COALESCE(sum(COALESCE(
      item.paying_amount_inc_tax, item.unit_price * item.quantity
    )) FILTER (WHERE item.item_type = 'service_charge'), 0), 2)
  INTO v_subtotal, v_vat, v_service_charge
  FROM public.order_items item
  WHERE item.order_id IN (
    SELECT payment.order_id
    FROM public.payments payment
    WHERE payment.combined_payment_group_id = v_group.id
      AND payment.restaurant_id = v_group.restaurant_id
  ) AND item.status <> 'cancelled';

  SELECT ROUND(COALESCE(sum(discount.discount_amount), 0), 2)
  INTO v_discount
  FROM public.order_discounts discount
  WHERE discount.order_id IN (
    SELECT payment.order_id
    FROM public.payments payment
    WHERE payment.combined_payment_group_id = v_group.id
      AND payment.restaurant_id = v_group.restaurant_id
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
  v_change := ROUND(COALESCE(
    p_change_amount,
    GREATEST(v_received - v_group.total_amount, 0)
  ), 2);
  v_receipt_number := 'BC-' ||
    to_char(v_group.completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD') ||
    '-' || lpad((('x' || substr(md5(v_group.id::text), 1, 8))::bit(32)::bigint
      % 1000000)::text, 6, '0');

  RETURN jsonb_build_object(
    'receipt_scope', 'combined',
    'combined_payment_group_id', v_group.id,
    'receipt_number', v_receipt_number,
    'order_id', v_primary_order_id,
    'order_ids', v_order_ids,
    'restaurant_name', v_profile.brand_name,
    'legal_name', v_profile.legal_name,
    'tax_code', v_profile.tax_code,
    'address_lines', v_address_lines,
    'table_number', v_table_numbers,
    'cashier_code', COALESCE(v_cashier, 'CASHIER'),
    'paid_at', v_group.completed_at,
    'items', v_items,
    'subtotal_amount', v_subtotal,
    'service_charge_amount', v_service_charge,
    'discount_amount', v_discount,
    'vat_amount', v_vat,
    'total_amount', v_group.total_amount,
    'payment_method', upper(v_group.method),
    'payments', jsonb_build_array(jsonb_build_object(
      'method', upper(v_group.method),
      'amount', v_group.total_amount,
      'is_revenue', true
    )),
    'received_amount', v_received,
    'change_amount', v_change,
    'is_service', false,
    'currency', 'VND'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.build_combined_customer_receipt_snapshot(
  uuid, numeric, numeric
) FROM PUBLIC, anon, authenticated;

-- This trigger runs after the existing alphabetically named print payload
-- enrichers and replaces their single-order assumptions with the canonical
-- combined snapshot.
CREATE OR REPLACE FUNCTION public.finalize_combined_print_receipt_payload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_snapshot jsonb;
BEGIN
  IF NEW.copy_type <> 'receipt'
     OR NEW.combined_payment_group_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_snapshot := public.build_combined_customer_receipt_snapshot(
    NEW.combined_payment_group_id,
    NULLIF(NEW.payload->>'combined_received_amount', '')::numeric,
    NULLIF(NEW.payload->>'combined_change_amount', '')::numeric
  );

  NEW.payload := COALESCE(NEW.payload, '{}'::jsonb) || v_snapshot ||
    jsonb_build_object(
      'ticket', 'receipt',
      'is_combined', true,
      'combined_payment_group_id', NEW.combined_payment_group_id,
      'ticket_code', substring(NEW.combined_payment_group_id::text from 1 for 8),
      'batch_no', NEW.batch_no,
      'at', v_snapshot->>'paid_at',
      'combined_receipt_number', v_snapshot->>'receipt_number',
      'combined_cashier_code', v_snapshot->>'cashier_code',
      'combined_subtotal_amount', (v_snapshot->>'subtotal_amount')::numeric,
      'combined_discount_amount', (v_snapshot->>'discount_amount')::numeric,
      'combined_vat_amount', (v_snapshot->>'vat_amount')::numeric,
      'combined_received_amount', (v_snapshot->>'received_amount')::numeric,
      'combined_change_amount', (v_snapshot->>'change_amount')::numeric
    );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_combined_print_receipt_payload()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_finalize_combined_print_receipt_payload
  ON public.print_jobs;
CREATE TRIGGER zz_finalize_combined_print_receipt_payload
BEFORE INSERT OR UPDATE OF payload ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.finalize_combined_print_receipt_payload();

-- Existing single-order digital receipts keep their order-local Vietnamese
-- trigger. Canonical combined rows have no order_id, so restore their complete
-- group snapshot after that legacy trigger has run.
CREATE OR REPLACE FUNCTION public.finalize_combined_digital_receipt_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
BEGIN
  IF NEW.order_id IS NULL AND NEW.combined_payment_group_id IS NOT NULL THEN
    NEW.snapshot := public.build_combined_customer_receipt_snapshot(
      NEW.combined_payment_group_id,
      NULLIF(NEW.snapshot->>'received_amount', '')::numeric,
      NULLIF(NEW.snapshot->>'change_amount', '')::numeric
    );
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_combined_digital_receipt_snapshot()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_finalize_combined_digital_receipt_snapshot
  ON public.digital_receipts;
CREATE TRIGGER zz_finalize_combined_digital_receipt_snapshot
BEFORE INSERT ON public.digital_receipts
FOR EACH ROW EXECUTE FUNCTION public.finalize_combined_digital_receipt_snapshot();

CREATE OR REPLACE FUNCTION public.ensure_combined_digital_receipt(
  p_group_id uuid,
  p_received_amount numeric DEFAULT NULL,
  p_change_amount numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_group public.combined_payment_groups%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
  v_snapshot jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_FORBIDDEN';
  END IF;

  SELECT * INTO v_group
  FROM public.combined_payment_groups
  WHERE id = p_group_id
  FOR UPDATE;

  IF NOT FOUND OR v_group.status <> 'completed' THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PAYMENT_REQUIRED';
  END IF;

  IF NOT public.is_super_admin() AND NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = v_group.restaurant_id
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE combined_payment_group_id = v_group.id
    AND order_id IS NULL
  FOR UPDATE;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'receipt_id', v_receipt.id,
      'receipt_number', v_receipt.receipt_number,
      'created', false,
      'snapshot', v_receipt.snapshot
    );
  END IF;

  v_snapshot := public.build_combined_customer_receipt_snapshot(
    v_group.id, p_received_amount, p_change_amount
  );

  INSERT INTO public.digital_receipts (
    restaurant_id, order_id, combined_payment_group_id,
    receipt_number, snapshot
  ) VALUES (
    v_group.restaurant_id,
    NULL,
    v_group.id,
    v_snapshot->>'receipt_number',
    v_snapshot
  )
  ON CONFLICT (combined_payment_group_id)
    WHERE order_id IS NULL AND combined_payment_group_id IS NOT NULL
  DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT * INTO v_receipt
    FROM public.digital_receipts
    WHERE combined_payment_group_id = v_group.id
      AND order_id IS NULL;
  END IF;

  INSERT INTO public.audit_logs (
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(), 'ensure_combined_digital_receipt', 'digital_receipts',
    v_receipt.id, jsonb_build_object(
      'store_id', v_group.restaurant_id,
      'combined_payment_group_id', v_group.id,
      'receipt_number', v_receipt.receipt_number
    )
  );

  RETURN jsonb_build_object(
    'receipt_id', v_receipt.id,
    'receipt_number', v_receipt.receipt_number,
    'created', true,
    'snapshot', v_receipt.snapshot
  );
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_combined_digital_receipt(
  uuid, numeric, numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_combined_digital_receipt(
  uuid, numeric, numeric
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.show_combined_customer_receipt_display(
  p_store_id uuid,
  p_group_id uuid,
  p_receipt_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
  v_primary_order_id uuid;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE id = p_receipt_id
    AND restaurant_id = p_store_id
    AND combined_payment_group_id = p_group_id
    AND order_id IS NULL
    AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_UNAVAILABLE';
  END IF;

  SELECT payment.order_id
  INTO v_primary_order_id
  FROM public.payments payment
  WHERE payment.combined_payment_group_id = p_group_id
    AND payment.restaurant_id = p_store_id
  ORDER BY payment.order_id
  LIMIT 1;

  IF v_primary_order_id IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_UNAVAILABLE';
  END IF;

  INSERT INTO public.customer_payment_displays (
    store_id, order_id, status, payload,
    shown_by_user_id, shown_at, updated_at
  ) VALUES (
    p_store_id,
    v_primary_order_id,
    'showing',
    jsonb_build_object(
      'phase', 'receipt',
      'display_revision', gen_random_uuid(),
      'order_id', v_primary_order_id,
      'receipt_id', p_receipt_id,
      'combined_payment_group_id', p_group_id,
      'is_combined', true,
      'table_number', v_receipt.snapshot->>'table_number',
      'total', COALESCE((v_receipt.snapshot->>'total_amount')::numeric, 0)
    ),
    v_actor.id,
    now(),
    now()
  ) ON CONFLICT (store_id) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    status = EXCLUDED.status,
    payload = EXCLUDED.payload,
    shown_by_user_id = EXCLUDED.shown_by_user_id,
    shown_at = EXCLUDED.shown_at,
    updated_at = EXCLUDED.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.show_combined_customer_receipt_display(
  uuid, uuid, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.show_combined_customer_receipt_display(
  uuid, uuid, uuid
) TO authenticated;

-- Repair only jobs that have not produced paper yet. Completed historical
-- print jobs remain immutable; a reprint receives the corrected snapshot.
UPDATE public.print_jobs
SET payload = payload
WHERE combined_payment_group_id IS NOT NULL
  AND copy_type = 'receipt'
  AND status IN ('pending', 'failed');

DO $$
DECLARE
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_missing
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'digital_receipts'
    AND column_name = 'order_id'
    AND is_nullable = 'YES';
  IF v_missing <> 1 THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_ORDER_NULLABILITY_VERIFY_FAILED';
  END IF;

  IF to_regprocedure(
    'public.ensure_combined_digital_receipt(uuid,numeric,numeric)'
  ) IS NULL OR to_regprocedure(
    'public.show_combined_customer_receipt_display(uuid,uuid,uuid)'
  ) IS NULL OR to_regprocedure(
    'public.build_combined_customer_receipt_snapshot(uuid,numeric,numeric)'
  ) IS NULL THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_FUNCTION_VERIFY_FAILED';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.ensure_combined_digital_receipt(uuid,numeric,numeric)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.show_combined_customer_receipt_display(uuid,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_GRANT_VERIFY_FAILED';
  END IF;

  SELECT count(*) INTO v_missing
  FROM pg_trigger
  WHERE tgrelid IN (
      'public.print_jobs'::regclass,
      'public.digital_receipts'::regclass
    )
    AND tgname IN (
      'zz_finalize_combined_print_receipt_payload',
      'zz_finalize_combined_digital_receipt_snapshot'
    )
    AND tgenabled <> 'D'
    AND NOT tgisinternal;
  IF v_missing <> 2 THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_FINALIZER_TRIGGER_VERIFY_FAILED:%',
      v_missing;
  END IF;
END;
$$;

COMMIT;
