BEGIN;

-- Add a separate operational copy type. Customer payment receipts and all
-- existing enqueue functions keep their current contracts.
ALTER TABLE public.print_jobs
  DROP CONSTRAINT IF EXISTS print_jobs_copy_type_check;

ALTER TABLE public.print_jobs
  ADD CONSTRAINT print_jobs_copy_type_check
  CHECK (
    copy_type IN (
      'kitchen',
      'floor',
      'tray',
      'confirmation',
      'receipt',
      'delivery_driver_receipt'
    )
  );

-- Keep the operational slip on its dedicated, receipt-printer-only path.
-- In particular, the pre-existing generic reprint RPC copies a stored payload
-- and routes unknown copy types to a kitchen printer. Driver receipt reprints
-- must instead be rebuilt from the current approved direct-order snapshot.
CREATE OR REPLACE FUNCTION public.guard_direct_delivery_driver_receipt_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_menu_total numeric;
  v_service_charge_total numeric;
  v_delivery_fee_total numeric;
  v_final_total numeric;
BEGIN
  IF NEW.copy_type <> 'delivery_driver_receipt' THEN
    RETURN NEW;
  END IF;

  IF NEW.payload ? 'reprint_of' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_USE_DEDICATED_REPRINT';
  END IF;

  IF NEW.status IN ('pending', 'printing', 'failed') THEN
    IF NEW.payload->>'ticket' IS DISTINCT FROM 'delivery_driver_receipt'
       OR NULLIF(btrim(NEW.payload->>'customer_name'), '') IS NULL
       OR NULLIF(btrim(NEW.payload->>'customer_phone'), '') IS NULL
       OR NULLIF(btrim(NEW.payload->>'formatted_address'), '') IS NULL
       OR NULLIF(btrim(NEW.payload->>'detail_address'), '') IS NULL
       OR jsonb_typeof(NEW.payload->'items') IS DISTINCT FROM 'array'
       OR jsonb_array_length(NEW.payload->'items') = 0
       OR COALESCE((NEW.payload->>'paid')::boolean, false) = false
       OR COALESCE((NEW.payload->>'customer_due')::numeric, 1) <> 0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_PAYLOAD_INVALID';
    END IF;

    v_menu_total := (NEW.payload->>'menu_total')::numeric;
    v_service_charge_total :=
      (NEW.payload->>'service_charge_total')::numeric;
    v_delivery_fee_total :=
      (NEW.payload->>'delivery_fee_total')::numeric;
    v_final_total := (NEW.payload->>'final_total')::numeric;

    IF round(v_final_total, 2) IS DISTINCT FROM round(
      v_menu_total + v_service_charge_total + v_delivery_fee_total,
      2
    ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_TOTAL_MISMATCH';
    END IF;

    IF NEW.status IN ('pending', 'printing')
       AND NEW.destination_id IS NULL THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_DESTINATION_INVALID';
    END IF;

    IF NEW.destination_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
         FROM public.printer_destinations destination
         WHERE destination.id = NEW.destination_id
           AND destination.restaurant_id = NEW.restaurant_id
           AND destination.purpose = 'receipt'
       ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_DESTINATION_INVALID';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_direct_delivery_driver_receipt_job()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_direct_delivery_driver_receipt_job_trigger
  ON public.print_jobs;
CREATE TRIGGER guard_direct_delivery_driver_receipt_job_trigger
BEFORE INSERT OR UPDATE OF copy_type, status, payload, destination_id
ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.guard_direct_delivery_driver_receipt_job();

CREATE OR REPLACE FUNCTION public.redact_direct_delivery_driver_receipt_payload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
BEGIN
  IF NEW.copy_type = 'delivery_driver_receipt'
     AND NEW.status IN ('done', 'cancelled')
     AND (
       OLD.status IS DISTINCT FROM NEW.status
       OR COALESCE((NEW.payload->>'pii_redacted')::boolean, false) = false
     ) THEN
    NEW.payload := NEW.payload
      - 'customer_name'
      - 'customer_phone'
      - 'formatted_address'
      - 'detail_address'
      || jsonb_build_object(
        'pii_redacted', true,
        'pii_redacted_at', now()
      );
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.redact_direct_delivery_driver_receipt_payload()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS redact_direct_delivery_driver_receipt_payload_trigger
  ON public.print_jobs;
CREATE TRIGGER redact_direct_delivery_driver_receipt_payload_trigger
BEFORE UPDATE OF status, payload ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.redact_direct_delivery_driver_receipt_payload();

CREATE OR REPLACE FUNCTION public.cleanup_expired_delivery_driver_receipt_jobs()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  UPDATE public.print_jobs job
  SET status = 'cancelled',
      last_error = 'DRIVER_RECEIPT_PII_EXPIRED',
      updated_at = now()
  WHERE job.copy_type = 'delivery_driver_receipt'
    AND job.status IN ('pending', 'printing', 'failed')
    AND job.created_at < now() - interval '24 hours';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_delivery_driver_receipt_jobs()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_delivery_driver_receipt_jobs()
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_driver_receipt_status(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_order_id uuid;
  v_job public.print_jobs%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
      AND request_row.restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND';
  END IF;

  SELECT financial.order_id
  INTO v_order_id
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;

  IF v_order_id IS NULL THEN
    RETURN jsonb_build_object(
      'exists', false,
      'status', null,
      'batch_no', null,
      'last_error_code', null,
      'can_reprint', false
    );
  END IF;

  SELECT *
  INTO v_job
  FROM public.print_jobs job
  WHERE job.order_id = v_order_id
    AND job.restaurant_id = p_store_id
    AND job.copy_type = 'delivery_driver_receipt'
  ORDER BY job.batch_no DESC, job.created_at DESC, job.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'exists', false,
      'status', null,
      'batch_no', null,
      'last_error_code', null,
      'can_reprint', false
    );
  END IF;

  RETURN jsonb_build_object(
    'exists', true,
    'job_id', v_job.id,
    'status', v_job.status,
    'batch_no', v_job.batch_no,
    'last_error_code', CASE
      WHEN v_job.last_error IS NULL THEN null
      WHEN v_job.last_error = 'NO_DESTINATION' THEN 'NO_DESTINATION'
      WHEN v_job.last_error = 'DRIVER_RECEIPT_PII_EXPIRED'
        THEN 'DRIVER_RECEIPT_PII_EXPIRED'
      ELSE 'PRINT_FAILED'
    END,
    'can_reprint', EXISTS (
      SELECT 1
      FROM public.print_jobs completed_job
      WHERE completed_job.order_id = v_order_id
        AND completed_job.restaurant_id = p_store_id
        AND completed_job.copy_type = 'delivery_driver_receipt'
        AND completed_job.status = 'done'
    ),
    'updated_at', v_job.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_driver_receipt_status(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_driver_receipt_status(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_direct_delivery_driver_receipt(
  p_store_id uuid,
  p_request_id uuid,
  p_reprint boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
  v_financial public.direct_order_financials%ROWTYPE;
  v_address public.direct_order_request_addresses%ROWTYPE;
  v_job public.print_jobs%ROWTYPE;
  v_destination_id uuid;
  v_batch_no integer := 1;
  v_status text := 'pending';
  v_error text;
  v_items jsonb := '[]'::jsonb;
  v_payload jsonb;
  v_restaurant_name text;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-driver-receipt:' || p_request_id::text, 0)
  );

  SELECT *
  INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND';
  END IF;

  SELECT *
  INTO v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED';
  END IF;

  IF round(v_financial.final_total, 2) IS DISTINCT FROM round(
    v_financial.menu_total
      + v_financial.service_charge_total
      + v_financial.delivery_fee_total,
    2
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_TOTAL_MISMATCH';
  END IF;

  SELECT *
  INTO v_address
  FROM public.direct_order_request_addresses address
  WHERE address.request_id = p_request_id
    AND address.restaurant_id = p_store_id;
  IF NOT FOUND
     OR NULLIF(btrim(v_address.customer_name), '') IS NULL
     OR NULLIF(btrim(v_address.customer_phone), '') IS NULL
     OR NULLIF(btrim(v_address.formatted_address), '') IS NULL
     OR NULLIF(btrim(v_address.detail_address), '') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE';
  END IF;

  SELECT destination.id
  INTO v_destination_id
  FROM public.printer_destinations destination
  WHERE destination.restaurant_id = p_store_id
    AND destination.purpose = 'receipt'
    AND destination.is_active = true
  ORDER BY destination.created_at, destination.id
  LIMIT 1;

  IF NOT COALESCE(p_reprint, false) THEN
    SELECT *
    INTO v_job
    FROM public.print_jobs job
    WHERE job.order_id = v_financial.order_id
      AND job.restaurant_id = p_store_id
      AND job.copy_type = 'delivery_driver_receipt'
      AND job.batch_no = 1
    ORDER BY job.created_at DESC, job.id DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      IF v_job.status = 'failed' THEN
        UPDATE public.print_jobs
        SET destination_id = COALESCE(v_destination_id, destination_id),
            status = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN 'failed'
              ELSE 'pending'
            END,
            attempts = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN attempts
              ELSE 0
            END,
            next_retry_at = now(),
            last_error = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN 'NO_DESTINATION'
              ELSE NULL
            END,
            updated_at = now()
        WHERE id = v_job.id
        RETURNING * INTO v_job;
      END IF;

      RETURN jsonb_build_object(
        'job_id', v_job.id,
        'status', v_job.status,
        'batch_no', v_job.batch_no,
        'idempotent', true
      );
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1
      FROM public.print_jobs job
      WHERE job.order_id = v_financial.order_id
        AND job.restaurant_id = p_store_id
        AND job.copy_type = 'delivery_driver_receipt'
        AND job.status = 'done'
    ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_REPRINT_NOT_AVAILABLE';
    END IF;

    SELECT *
    INTO v_job
    FROM public.print_jobs job
    WHERE job.order_id = v_financial.order_id
      AND job.restaurant_id = p_store_id
      AND job.copy_type = 'delivery_driver_receipt'
    ORDER BY job.batch_no DESC, job.created_at DESC, job.id DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND AND v_job.status IN ('pending', 'printing', 'failed') THEN
      IF v_job.status = 'failed' THEN
        UPDATE public.print_jobs
        SET destination_id = COALESCE(v_destination_id, destination_id),
            status = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN 'failed'
              ELSE 'pending'
            END,
            attempts = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN attempts
              ELSE 0
            END,
            next_retry_at = now(),
            last_error = CASE
              WHEN COALESCE(v_destination_id, destination_id) IS NULL
                THEN 'NO_DESTINATION'
              ELSE NULL
            END,
            updated_at = now()
        WHERE id = v_job.id
        RETURNING * INTO v_job;
      END IF;

      RETURN jsonb_build_object(
        'job_id', v_job.id,
        'status', v_job.status,
        'batch_no', v_job.batch_no,
        'idempotent', true
      );
    END IF;

    SELECT COALESCE(max(job.batch_no), 0) + 1
    INTO v_batch_no
    FROM public.print_jobs job
    WHERE job.order_id = v_financial.order_id
      AND job.restaurant_id = p_store_id
      AND job.copy_type = 'delivery_driver_receipt';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'label', COALESCE(
          NULLIF(item.name_vi, ''),
          NULLIF(item.display_name, ''),
          'Mon'
        ),
        'quantity', item.quantity,
        'unit_price', item.unit_price
      )
      ORDER BY item.sort_order, item.id
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.direct_order_request_items item
  WHERE item.request_id = p_request_id
    AND item.restaurant_id = p_store_id;

  IF jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DRIVER_RECEIPT_ITEMS_UNAVAILABLE';
  END IF;

  SELECT restaurant.name
  INTO v_restaurant_name
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id;

  IF v_destination_id IS NULL THEN
    v_status := 'failed';
    v_error := 'NO_DESTINATION';
  END IF;

  v_payload := jsonb_build_object(
    'ticket', 'delivery_driver_receipt',
    'restaurant_name', COALESCE(v_restaurant_name, 'GLOBOS POS'),
    'reference_code', v_request.reference_code,
    'ticket_code', v_request.reference_code,
    'batch_no', v_batch_no,
    'printed_reason', CASE
      WHEN COALESCE(p_reprint, false) THEN 'reprint'
      ELSE 'driver_handoff'
    END,
    'at', to_char(
      now() AT TIME ZONE 'Asia/Ho_Chi_Minh',
      'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'
    ),
    'customer_name', v_address.customer_name,
    'customer_phone', v_address.customer_phone,
    'formatted_address', v_address.formatted_address,
    'detail_address', v_address.detail_address,
    'items', v_items,
    'menu_total', v_financial.menu_total,
    'service_charge_total', v_financial.service_charge_total,
    'delivery_fee_total', v_financial.delivery_fee_total,
    'final_total', v_financial.final_total,
    'customer_due', 0,
    'paid', true,
    'pii_redacted', false
  );

  INSERT INTO public.print_jobs(
    restaurant_id,
    order_id,
    copy_type,
    batch_no,
    destination_id,
    payload,
    status,
    last_error,
    fulfillment_mode_snapshot
  ) VALUES (
    p_store_id,
    v_financial.order_id,
    'delivery_driver_receipt',
    v_batch_no,
    v_destination_id,
    v_payload,
    v_status,
    v_error,
    'pos_print'
  )
  RETURNING * INTO v_job;

  INSERT INTO public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'enqueue_direct_delivery_driver_receipt',
    'print_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'request_id', p_request_id,
      'order_id', v_financial.order_id,
      'batch_no', v_batch_no,
      'reprint', COALESCE(p_reprint, false),
      'status', v_status,
      'updated_at_utc', now()
    )
  );

  RETURN jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'batch_no', v_job.batch_no,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_direct_delivery_driver_receipt(
  uuid, uuid, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_direct_delivery_driver_receipt(
  uuid, uuid, boolean
) TO authenticated, service_role;

DO $schedule$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN
      SELECT jobid
      FROM cron.job
      WHERE jobname = 'delivery-driver-receipt-pii-cleanup-hourly'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;

    PERFORM cron.schedule(
      'delivery-driver-receipt-pii-cleanup-hourly',
      '7 * * * *',
      'SELECT public.cleanup_expired_delivery_driver_receipt_jobs();'
    );
  ELSE
    RAISE NOTICE 'pg_cron unavailable; skipped driver receipt PII cleanup schedule.';
  END IF;
END;
$schedule$;

DO $verification$
DECLARE
  v_constraint text;
  v_guard_trigger_enabled "char";
  v_trigger_enabled "char";
BEGIN
  SELECT pg_get_constraintdef(constraint_row.oid)
  INTO v_constraint
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.print_jobs'::regclass
    AND constraint_row.conname = 'print_jobs_copy_type_check';

  IF v_constraint NOT LIKE '%delivery_driver_receipt%'
     OR v_constraint NOT LIKE '%receipt%'
     OR v_constraint NOT LIKE '%confirmation%' THEN
    RAISE EXCEPTION 'DELIVERY_DRIVER_RECEIPT_COPY_TYPE_VERIFICATION_FAILED';
  END IF;

  SELECT trigger_row.tgenabled
  INTO v_guard_trigger_enabled
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.print_jobs'::regclass
    AND trigger_row.tgname =
      'guard_direct_delivery_driver_receipt_job_trigger'
    AND NOT trigger_row.tgisinternal;

  IF v_guard_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'DELIVERY_DRIVER_RECEIPT_GUARD_TRIGGER_MISSING';
  END IF;

  SELECT trigger_row.tgenabled
  INTO v_trigger_enabled
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.print_jobs'::regclass
    AND trigger_row.tgname =
      'redact_direct_delivery_driver_receipt_payload_trigger'
    AND NOT trigger_row.tgisinternal;

  IF v_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'DELIVERY_DRIVER_RECEIPT_REDACTION_TRIGGER_MISSING';
  END IF;

  IF to_regprocedure(
       'public.enqueue_direct_delivery_driver_receipt(uuid,uuid,boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.direct_order_driver_receipt_status(uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_DRIVER_RECEIPT_RPC_VERIFICATION_FAILED';
  END IF;
END;
$verification$;

COMMIT;
