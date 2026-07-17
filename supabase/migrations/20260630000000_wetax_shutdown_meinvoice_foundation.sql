-- Wetax shutdown + MISA meInvoice foundation.
-- Restaurant POS only. Photo Objet uses separate photo_objet_* tables and is
-- intentionally outside this cash-register invoice queue.

BEGIN;

INSERT INTO public.system_config (key, value, description)
VALUES
  (
    'wetax_dispatch_enabled',
    'false',
    'PERMANENT SHUTDOWN: WeTax service is no longer used. Historical rows remain read-only for audit.'
  ),
  (
    'wetax_polling_enabled',
    'false',
    'PERMANENT SHUTDOWN: WeTax polling is disabled. Historical rows remain read-only for audit.'
  ),
  (
    'wetax_shutdown_permanent',
    'true',
    'Hard gate documenting that no new WeTax dispatch/poll/onboarding work should be created.'
  ),
  (
    'meinvoice_dispatch_enabled',
    'false',
    'MISA meInvoice API dispatch gate. Keep false until MISA app_id/API activation and payment method labels are confirmed.'
  )
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobname)
    FROM cron.job
    WHERE jobname IN (
      'wetax-dispatcher-every-minute',
      'wetax-poller-every-2-minutes',
      'wetax-daily-close-00-hcmc',
      'wetax-commons-refresh-weekly'
    );
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function THEN
    RAISE NOTICE 'pg_cron is unavailable; skipped WeTax cron unschedule.';
END
$$;

ALTER TABLE public.tax_entity
  DROP CONSTRAINT IF EXISTS tax_entity_einvoice_provider_check;

ALTER TABLE public.tax_entity
  ADD CONSTRAINT tax_entity_einvoice_provider_check
  CHECK (einvoice_provider IN ('wetax', 'meinvoice'));

UPDATE public.tax_entity
SET einvoice_provider = 'meinvoice',
    updated_at = now()
WHERE einvoice_provider = 'wetax'
  AND tax_code <> 'PLACEHOLDER_DEV_000';

COMMENT ON COLUMN public.tax_entity.einvoice_provider IS
  'E-invoice provider. WeTax is historical only; new restaurant cash-register invoices use meInvoice.';

CREATE TABLE IF NOT EXISTS public.meinvoice_tax_entity_config (
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  api_base_url text NOT NULL DEFAULT 'https://app3.meinvoice.vn/api/integration',
  app_id text,
  invoice_series text,
  payment_method_cash text NOT NULL DEFAULT 'Tiền mặt',
  payment_method_card text NOT NULL DEFAULT 'Thẻ quốc tế',
  payment_method_pay text NOT NULL DEFAULT 'Ví điện tử/QR',
  payment_method_mixed text NOT NULL DEFAULT 'Tiền mặt/Thẻ/Ví điện tử',
  integration_status text NOT NULL DEFAULT 'needs_vendor_activation'
    CHECK (integration_status IN (
      'needs_vendor_activation',
      'configured',
      'active',
      'paused'
    )),
  last_verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.meinvoice_tax_entity_config IS
  'Non-secret MISA meInvoice configuration per seller. Credentials/tokens must remain in secure runtime secrets, not this table.';

CREATE TABLE IF NOT EXISTS public.meinvoice_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'meinvoice' CHECK (provider = 'meinvoice'),
  invoice_form text NOT NULL DEFAULT 'cash_register' CHECK (invoice_form = 'cash_register'),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  buyer_kind text NOT NULL DEFAULT 'anonymous'
    CHECK (buyer_kind IN ('anonymous', 'registered', 'manual')),
  buyer_snapshot jsonb NOT NULL DEFAULT jsonb_build_object(
    'customer_name',
    'Người mua không lấy hóa đơn'
  ),
  payment_method_snapshot text NOT NULL,
  payment_summary jsonb NOT NULL DEFAULT '[]'::jsonb,
  line_items_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending_manual_config'
    CHECK (status IN (
      'pending_manual_config',
      'pending',
      'dispatch_paused',
      'sent_to_misa',
      'sent_to_tax_authority',
      'valid_invoice',
      'failed',
      'manual_action_required',
      'resolved'
    )),
  manual_action_type text CHECK (
    manual_action_type IS NULL OR manual_action_type IN (
      'buyer_info_after_issue',
      'replace',
      'adjust',
      'incorrect_invoice_notice',
      'misa_portal_review'
    )
  ),
  manual_action_note text,
  misa_ref_id text,
  transaction_id text,
  invoice_series text,
  invoice_number text,
  tax_authority_code text,
  search_code text,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id)
);

COMMENT ON TABLE public.meinvoice_jobs IS
  'Restaurant POS cash-register invoice queue for MISA meInvoice. Covers first issuance only; replacement/adjustment/error notices are manual in the MISA portal.';
COMMENT ON COLUMN public.meinvoice_jobs.buyer_snapshot IS
  'Snapshot of POS buyer fields. Anonymous default is "Người mua không lấy hóa đơn".';
COMMENT ON COLUMN public.meinvoice_jobs.manual_action_type IS
  'Post-issuance exception marker. MISA portal handles replace/adjust/incorrect-invoice notice manually.';

CREATE INDEX IF NOT EXISTS idx_meinvoice_jobs_store_status_created
  ON public.meinvoice_jobs (store_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_meinvoice_jobs_tax_entity_status_created
  ON public.meinvoice_jobs (tax_entity_id, status, created_at);

ALTER TABLE public.meinvoice_tax_entity_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meinvoice_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "meinvoice_tax_entity_config_store_read"
  ON public.meinvoice_tax_entity_config;
CREATE POLICY "meinvoice_tax_entity_config_store_read"
  ON public.meinvoice_tax_entity_config
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.restaurants r
      JOIN public.user_accessible_stores(auth.uid()) s(store_id)
        ON s.store_id = r.id
      WHERE r.tax_entity_id = meinvoice_tax_entity_config.tax_entity_id
    )
  );

DROP POLICY IF EXISTS "meinvoice_jobs_store_read"
  ON public.meinvoice_jobs;
CREATE POLICY "meinvoice_jobs_store_read"
  ON public.meinvoice_jobs
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = meinvoice_jobs.store_id
    )
  );

CREATE OR REPLACE FUNCTION public.block_wetax_einvoice_job_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  BEGIN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'wetax_einvoice_job_insert_blocked',
      'einvoice_jobs',
      NULL,
      jsonb_build_object(
        'reason', 'wetax_shutdown_permanent',
        'order_id', NEW.order_id,
        'ref_id', NEW.ref_id,
        'attempted_status', NEW.status
      )
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'WeTax insert blocked; audit log failed: %', SQLERRM;
  END;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_wetax_einvoice_job_insert
  ON public.einvoice_jobs;
CREATE TRIGGER trg_block_wetax_einvoice_job_insert
  BEFORE INSERT ON public.einvoice_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.block_wetax_einvoice_job_insert();

COMMENT ON FUNCTION public.block_wetax_einvoice_job_insert() IS
  'Permanent WeTax shutdown guard. Returning NULL skips legacy einvoice_jobs inserts without raising, so payment completion remains independent.';

CREATE OR REPLACE FUNCTION public.meinvoice_payment_method_label(
  p_tax_entity_id uuid,
  p_methods text[]
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_methods text[] := COALESCE(p_methods, ARRAY[]::text[]);
  v_method text;
  v_config public.meinvoice_tax_entity_config%ROWTYPE;
BEGIN
  SELECT *
  INTO v_config
  FROM public.meinvoice_tax_entity_config
  WHERE tax_entity_id = p_tax_entity_id;

  IF array_length(v_methods, 1) IS NULL THEN
    RETURN COALESCE(v_config.payment_method_mixed, 'Tiền mặt/Thẻ/Ví điện tử');
  END IF;

  IF array_length(v_methods, 1) > 1 THEN
    RETURN COALESCE(v_config.payment_method_mixed, 'Tiền mặt/Thẻ/Ví điện tử');
  END IF;

  v_method := v_methods[1];

  IF v_method = 'CASH' THEN
    RETURN COALESCE(v_config.payment_method_cash, 'Tiền mặt');
  ELSIF v_method IN ('CREDITCARD', 'ATM') THEN
    RETURN COALESCE(v_config.payment_method_card, 'Thẻ quốc tế');
  ELSE
    RETURN COALESCE(v_config.payment_method_pay, 'Ví điện tử/QR');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_meinvoice_cash_register_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_tax_entity_id uuid;
  v_tax_code text;
  v_config_status text;
  v_payment_methods text[];
  v_payment_method_snapshot text;
  v_payment_summary jsonb := '[]'::jsonb;
  v_line_items_snapshot jsonb := '[]'::jsonb;
  v_status text := 'pending_manual_config';
BEGIN
  IF TG_OP <> 'UPDATE'
     OR NEW.status <> 'completed'
     OR COALESCE(OLD.status, '') = 'completed' THEN
    RETURN NEW;
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = NEW.restaurant_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(m.integration_status, 'needs_vendor_activation')
  INTO v_config_status
  FROM public.meinvoice_tax_entity_config m
  WHERE m.tax_entity_id = v_tax_entity_id;

  v_status := CASE
    WHEN COALESCE(v_config_status, 'needs_vendor_activation') = 'active'
     AND COALESCE((
       SELECT value = 'true'
       FROM public.system_config
       WHERE key = 'meinvoice_dispatch_enabled'
     ), false)
      THEN 'pending'
    ELSE 'pending_manual_config'
  END;

  SELECT COALESCE(array_agg(DISTINCT p.method ORDER BY p.method), ARRAY[]::text[])
  INTO v_payment_methods
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  v_payment_method_snapshot :=
    public.meinvoice_payment_method_label(v_tax_entity_id, v_payment_methods);

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'payment_id', p.id,
        'method', p.method,
        'amount', p.amount,
        'amount_portion', p.amount_portion,
        'created_at', p.created_at
      )
      ORDER BY p.created_at
    ),
    '[]'::jsonb
  )
  INTO v_payment_summary
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'order_item_id', oi.id,
        'item_type', oi.item_type,
        'display_name', COALESCE(NULLIF(oi.display_name, ''), oi.label, 'Item'),
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'vat_rate', oi.vat_rate,
        'vat_amount', oi.vat_amount,
        'total_amount_ex_tax', oi.total_amount_ex_tax,
        'paying_amount_inc_tax', oi.paying_amount_inc_tax
      )
      ORDER BY oi.created_at, oi.id
    ),
    '[]'::jsonb
  )
  INTO v_line_items_snapshot
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id
    AND oi.status <> 'cancelled';

  INSERT INTO public.meinvoice_jobs (
    order_id,
    store_id,
    tax_entity_id,
    buyer_kind,
    buyer_snapshot,
    payment_method_snapshot,
    payment_summary,
    line_items_snapshot,
    status
  )
  VALUES (
    NEW.id,
    NEW.restaurant_id,
    v_tax_entity_id,
    'anonymous',
    jsonb_build_object(
      'customer_name',
      'Người mua không lấy hóa đơn'
    ),
    v_payment_method_snapshot,
    v_payment_summary,
    v_line_items_snapshot,
    v_status
  )
  ON CONFLICT (order_id) DO NOTHING;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'meInvoice enqueue skipped for order %, error: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_meinvoice_cash_register_job
  ON public.orders;
CREATE TRIGGER trg_enqueue_meinvoice_cash_register_job
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'completed')
  EXECUTE FUNCTION public.enqueue_meinvoice_cash_register_job();

COMMENT ON FUNCTION public.enqueue_meinvoice_cash_register_job() IS
  'Creates the restaurant MISA meInvoice first-issuance queue row after order completion. It catches errors so payment completion is not blocked by invoicing.';

CREATE OR REPLACE FUNCTION public.request_red_invoice(
  p_order_id uuid,
  p_store_id uuid,
  p_buyer_tax_code text,
  p_buyer_name text,
  p_buyer_address text,
  p_receiver_email text,
  p_receiver_email_cc text DEFAULT NULL,
  p_buyer_tel text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_job public.meinvoice_jobs%ROWTYPE;
  v_tax_entity_id uuid;
  v_tax_code text;
  v_manual_action_required boolean := false;
  v_photo_objet_brand_id constant uuid := '77000000-0000-0000-0000-000000000001';
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants r
    WHERE r.id = p_store_id
      AND r.brand_id = v_photo_objet_brand_id
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET';
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = p_store_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RAISE EXCEPTION 'TAX_ENTITY_NOT_READY';
  END IF;

  SELECT *
  INTO v_job
  FROM public.meinvoice_jobs
  WHERE order_id = p_order_id
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.meinvoice_jobs (
      order_id,
      store_id,
      tax_entity_id,
      buyer_kind,
      buyer_snapshot,
      payment_method_snapshot,
      status
    )
    VALUES (
      p_order_id,
      p_store_id,
      v_tax_entity_id,
      'anonymous',
      jsonb_build_object('customer_name', 'Người mua không lấy hóa đơn'),
      public.meinvoice_payment_method_label(v_tax_entity_id, ARRAY[]::text[]),
      'pending_manual_config'
    )
    RETURNING * INTO v_job;
  END IF;

  v_manual_action_required :=
    v_job.status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice');

  UPDATE public.meinvoice_jobs
  SET
    buyer_kind = 'registered',
    buyer_snapshot = jsonb_build_object(
      'tax_code', COALESCE(p_buyer_tax_code, ''),
      'unit_name', COALESCE(p_buyer_name, ''),
      'address', COALESCE(p_buyer_address, ''),
      'buyer_full_name', '',
      'email', p_receiver_email,
      'email_cc', COALESCE(p_receiver_email_cc, ''),
      'phone', COALESCE(p_buyer_tel, ''),
      'source', 'restaurant_pos'
    ),
    status = CASE
      WHEN v_manual_action_required THEN 'manual_action_required'
      ELSE status
    END,
    manual_action_type = CASE
      WHEN v_manual_action_required THEN 'buyer_info_after_issue'
      ELSE manual_action_type
    END,
    manual_action_note = CASE
      WHEN v_manual_action_required THEN
        'Buyer VAT information was entered after the invoice had already been sent; handle replace/adjust/incorrect-invoice notice manually in MISA.'
      ELSE manual_action_note
    END,
    updated_at = now()
  WHERE id = v_job.id
  RETURNING * INTO v_job;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO public.b2b_buyer_cache (
      store_id,
      buyer_tax_code,
      tax_company_name,
      tax_address,
      receiver_email,
      receiver_email_cc,
      first_used_at,
      last_used_at,
      use_count,
      tax_entity_id
    )
    VALUES (
      p_store_id,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(),
      now(),
      1,
      v_tax_entity_id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = public.b2b_buyer_cache.use_count + 1,
      tax_entity_id = EXCLUDED.tax_entity_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'meinvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'provider', 'meinvoice',
      'order_id', p_order_id,
      'store_id', p_store_id,
      'buyer_tax_code', p_buyer_tax_code,
      'receiver_email', p_receiver_email,
      'manual_action_required', v_manual_action_required
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'provider', 'meinvoice',
    'manual_action_required', v_manual_action_required
  );
END;
$$;

COMMIT;
