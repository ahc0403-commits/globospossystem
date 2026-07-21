-- Red invoice intake and separate Excel export.
-- The existing restaurant daily receipt export remains unchanged. This flow
-- only carries registered-buyer information keyed to the original order and
-- payment receipt IDs so the Windows automation can enrich, not duplicate,
-- the original sale.

BEGIN;

CREATE TABLE IF NOT EXISTS public.red_invoice_intakes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  meinvoice_job_id uuid REFERENCES public.meinvoice_jobs(id),
  receipt_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  sale_at timestamptz NOT NULL,
  gross_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
  payment_method text NOT NULL DEFAULT '',
  line_items_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(line_items_snapshot) = 'array'),
  source text NOT NULL DEFAULT 'cashier'
    CHECK (source IN ('cashier', 'business_card', 'zalo', 'other')),
  status text NOT NULL DEFAULT 'awaiting_information'
    CHECK (status IN (
      'awaiting_information',
      'ready',
      'exported',
      'completed',
      'manual_review',
      'cancelled'
    )),
  buyer_tax_code text,
  buyer_unit_code text,
  buyer_legal_name text,
  buyer_full_name text,
  buyer_address text,
  buyer_email text,
  buyer_email_cc text,
  buyer_phone text,
  buyer_id text,
  source_note text,
  attachment_urls text[] NOT NULL DEFAULT ARRAY[]::text[],
  requested_at timestamptz NOT NULL DEFAULT now(),
  requested_by uuid REFERENCES public.users(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id),
  ready_at timestamptz,
  exported_at timestamptz,
  export_batch_id uuid,
  completed_at timestamptz
);

COMMENT ON TABLE public.red_invoice_intakes IS
  'Temporary registered-buyer intake linked to an original POS order. Separate from the immutable all-receipts Excel and from the MISA post-issuance lifecycle.';
COMMENT ON COLUMN public.red_invoice_intakes.receipt_ids IS
  'Original payment IDs exported by restaurant_sales_YYYYMMDD.xlsx. Matching these IDs prevents duplicate sales.';
COMMENT ON COLUMN public.red_invoice_intakes.attachment_urls IS
  'Private signed URLs for business-card or Zalo evidence. Evidence is not the authoritative buyer record.';

CREATE INDEX IF NOT EXISTS idx_red_invoice_intakes_sale_status
  ON public.red_invoice_intakes (sale_at, status);
CREATE INDEX IF NOT EXISTS idx_red_invoice_intakes_store_sale
  ON public.red_invoice_intakes (store_id, sale_at);
CREATE INDEX IF NOT EXISTS idx_red_invoice_intakes_export_batch
  ON public.red_invoice_intakes (export_batch_id)
  WHERE export_batch_id IS NOT NULL;

ALTER TABLE public.red_invoice_intakes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.red_invoice_intakes FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS red_invoice_intakes_store_read
  ON public.red_invoice_intakes;
CREATE POLICY red_invoice_intakes_store_read
  ON public.red_invoice_intakes
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
      WHERE accessible.store_id = red_invoice_intakes.store_id
    )
  );

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'red-invoice-intake',
  'red-invoice-intake',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS storage_red_invoice_intake_scoped ON storage.objects;
CREATE POLICY storage_red_invoice_intake_scoped
  ON storage.objects
  FOR ALL
  TO authenticated
  USING (
    bucket_id = 'red-invoice-intake'
    AND (
      public.is_super_admin()
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
        WHERE accessible.store_id::text = (storage.foldername(name))[1]
      )
    )
  )
  WITH CHECK (
    bucket_id = 'red-invoice-intake'
    AND (
      public.is_super_admin()
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
        WHERE accessible.store_id::text = (storage.foldername(name))[1]
      )
    )
  );

CREATE OR REPLACE FUNCTION public.upsert_red_invoice_intake(
  p_order_id uuid,
  p_store_id uuid,
  p_source text DEFAULT 'cashier',
  p_status text DEFAULT 'awaiting_information',
  p_buyer_tax_code text DEFAULT NULL,
  p_buyer_unit_code text DEFAULT NULL,
  p_buyer_legal_name text DEFAULT NULL,
  p_buyer_full_name text DEFAULT NULL,
  p_buyer_address text DEFAULT NULL,
  p_buyer_email text DEFAULT NULL,
  p_buyer_email_cc text DEFAULT NULL,
  p_buyer_phone text DEFAULT NULL,
  p_buyer_id text DEFAULT NULL,
  p_source_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_job public.meinvoice_jobs%ROWTYPE;
  v_tax_entity_id uuid;
  v_tax_code text;
  v_receipt_ids text[];
  v_sale_at timestamptz;
  v_gross_amount numeric(18,2);
  v_payment_method text;
  v_payment_methods text[];
  v_line_items jsonb;
  v_effective_status text := p_status;
  v_intake public.red_invoice_intakes%ROWTYPE;
  v_existing_intake public.red_invoice_intakes%ROWTYPE;
  v_complete_buyer boolean;
  v_photo_objet_brand_id constant uuid :=
    '77000000-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN';
  END IF;

  IF p_source NOT IN ('cashier', 'business_card', 'zalo', 'other') THEN
    RAISE EXCEPTION 'RED_INVOICE_SOURCE_INVALID';
  END IF;
  IF p_status NOT IN (
    'awaiting_information', 'ready', 'exported', 'completed',
    'manual_review', 'cancelled'
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_STATUS_INVALID';
  END IF;
  IF v_actor.role = 'cashier'
     AND p_status NOT IN ('awaiting_information', 'ready') THEN
    RAISE EXCEPTION 'RED_INVOICE_STATUS_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
       WHERE accessible.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants restaurant
    WHERE restaurant.id = p_store_id
      AND restaurant.brand_id = v_photo_objet_brand_id
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET';
  END IF;

  SELECT restaurant.tax_entity_id, tax_entity.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants restaurant
  LEFT JOIN public.tax_entity tax_entity
    ON tax_entity.id = restaurant.tax_entity_id
  WHERE restaurant.id = p_store_id;
  IF v_tax_entity_id IS NULL
     OR v_tax_code IS NULL
     OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RAISE EXCEPTION 'TAX_ENTITY_NOT_READY';
  END IF;

  SELECT
    COALESCE(array_agg(payment.id::text ORDER BY payment.created_at), ARRAY[]::text[]),
    MIN(payment.created_at),
    COALESCE(SUM(payment.amount), 0)::numeric(18,2),
    COALESCE(string_agg(DISTINCT payment.method, ', ' ORDER BY payment.method), ''),
    COALESCE(array_agg(DISTINCT payment.method ORDER BY payment.method), ARRAY[]::text[])
  INTO v_receipt_ids, v_sale_at, v_gross_amount, v_payment_method,
       v_payment_methods
  FROM public.payments payment
  WHERE payment.order_id = p_order_id
    AND payment.restaurant_id = p_store_id
    AND payment.is_revenue = true;

  IF v_sale_at IS NULL OR cardinality(v_receipt_ids) = 0 THEN
    RAISE EXCEPTION 'PAID_RECEIPT_REQUIRED';
  END IF;

  SELECT * INTO v_job
  FROM public.meinvoice_jobs
  WHERE order_id = p_order_id
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.meinvoice_jobs (
      order_id, store_id, tax_entity_id, buyer_kind, buyer_snapshot,
      payment_method_snapshot, status
    ) VALUES (
      p_order_id, p_store_id, v_tax_entity_id, 'manual',
      jsonb_build_object(
        'customer_name', 'Red invoice information pending',
        'source', p_source,
        'source_note', COALESCE(p_source_note, '')
      ),
      public.meinvoice_payment_method_label(v_tax_entity_id, v_payment_methods),
      'dispatch_paused'
    )
    RETURNING * INTO v_job;
  END IF;

  v_payment_method := COALESCE(
    NULLIF(btrim(v_job.payment_method_snapshot), ''),
    public.meinvoice_payment_method_label(v_tax_entity_id, v_payment_methods)
  );

  v_line_items := COALESCE(v_job.line_items_snapshot, '[]'::jsonb);
  IF jsonb_array_length(v_line_items) = 0 THEN
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'order_item_id', item.id,
          'display_name', COALESCE(NULLIF(item.display_name, ''), item.label, 'Item'),
          'quantity', item.quantity,
          'unit_price', item.unit_price,
          'vat_rate', item.vat_rate,
          'vat_amount', item.vat_amount,
          'total_amount_ex_tax', item.total_amount_ex_tax,
          'paying_amount_inc_tax', item.paying_amount_inc_tax
        ) ORDER BY item.created_at, item.id
      ),
      '[]'::jsonb
    ) INTO v_line_items
    FROM public.order_items item
    WHERE item.order_id = p_order_id
      AND item.status <> 'cancelled';
  END IF;

  v_complete_buyer := p_status IN ('ready', 'exported', 'completed');
  IF v_complete_buyer AND (
    COALESCE(btrim(p_buyer_tax_code), '') = ''
    OR COALESCE(btrim(p_buyer_legal_name), '') = ''
    OR COALESCE(btrim(p_buyer_address), '') = ''
    OR COALESCE(btrim(p_buyer_email), '') = ''
    OR position('@' IN p_buyer_email) = 0
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE';
  END IF;

  IF v_job.id IS NOT NULL AND v_job.status IN (
    'sent_to_misa', 'sent_to_tax_authority', 'valid_invoice'
  ) THEN
    v_effective_status := 'manual_review';
  END IF;

  SELECT * INTO v_existing_intake
  FROM public.red_invoice_intakes
  WHERE order_id = p_order_id
  LIMIT 1;

  IF FOUND
     AND v_existing_intake.status IN ('exported', 'completed')
     AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_LOCKED';
  END IF;

  INSERT INTO public.red_invoice_intakes (
    order_id, store_id, tax_entity_id, meinvoice_job_id,
    receipt_ids, sale_at, gross_amount, payment_method, line_items_snapshot,
    source, status, buyer_tax_code, buyer_unit_code, buyer_legal_name,
    buyer_full_name, buyer_address, buyer_email, buyer_email_cc,
    buyer_phone, buyer_id, source_note, requested_by, updated_by, ready_at,
    completed_at
  ) VALUES (
    p_order_id, p_store_id, v_tax_entity_id, v_job.id,
    v_receipt_ids, v_sale_at, v_gross_amount, v_payment_method, v_line_items,
    p_source, v_effective_status, NULLIF(btrim(p_buyer_tax_code), ''),
    NULLIF(btrim(p_buyer_unit_code), ''), NULLIF(btrim(p_buyer_legal_name), ''),
    NULLIF(btrim(p_buyer_full_name), ''), NULLIF(btrim(p_buyer_address), ''),
    NULLIF(btrim(p_buyer_email), ''), NULLIF(btrim(p_buyer_email_cc), ''),
    NULLIF(btrim(p_buyer_phone), ''), NULLIF(btrim(p_buyer_id), ''),
    NULLIF(btrim(p_source_note), ''), v_actor.id, v_actor.id,
    CASE WHEN v_effective_status = 'ready' THEN now() ELSE NULL END,
    CASE WHEN v_effective_status = 'completed' THEN now() ELSE NULL END
  )
  ON CONFLICT (order_id) DO UPDATE SET
    source = EXCLUDED.source,
    status = EXCLUDED.status,
    buyer_tax_code = EXCLUDED.buyer_tax_code,
    buyer_unit_code = EXCLUDED.buyer_unit_code,
    buyer_legal_name = EXCLUDED.buyer_legal_name,
    buyer_full_name = EXCLUDED.buyer_full_name,
    buyer_address = EXCLUDED.buyer_address,
    buyer_email = EXCLUDED.buyer_email,
    buyer_email_cc = EXCLUDED.buyer_email_cc,
    buyer_phone = EXCLUDED.buyer_phone,
    buyer_id = EXCLUDED.buyer_id,
    source_note = EXCLUDED.source_note,
    receipt_ids = EXCLUDED.receipt_ids,
    sale_at = EXCLUDED.sale_at,
    gross_amount = EXCLUDED.gross_amount,
    payment_method = EXCLUDED.payment_method,
    line_items_snapshot = EXCLUDED.line_items_snapshot,
    meinvoice_job_id = EXCLUDED.meinvoice_job_id,
    updated_at = now(),
    updated_by = v_actor.id,
    ready_at = CASE
      WHEN EXCLUDED.status = 'ready' THEN COALESCE(red_invoice_intakes.ready_at, now())
      ELSE red_invoice_intakes.ready_at
    END,
    completed_at = CASE
      WHEN EXCLUDED.status = 'completed' THEN COALESCE(red_invoice_intakes.completed_at, now())
      ELSE red_invoice_intakes.completed_at
    END
  RETURNING * INTO v_intake;

  IF v_job.id IS NOT NULL THEN
    UPDATE public.meinvoice_jobs
    SET
      buyer_kind = CASE
        WHEN v_complete_buyer THEN 'registered'
        ELSE 'manual'
      END,
      buyer_snapshot = CASE
        WHEN v_complete_buyer THEN jsonb_build_object(
          'tax_code', COALESCE(p_buyer_tax_code, ''),
          'tin_cic_household_head_id', COALESCE(p_buyer_tax_code, ''),
          'unit_code', COALESCE(p_buyer_unit_code, ''),
          'unit_name', COALESCE(p_buyer_legal_name, ''),
          'address', COALESCE(p_buyer_address, ''),
          'buyer_full_name', COALESCE(p_buyer_full_name, ''),
          'email', COALESCE(p_buyer_email, ''),
          'email_cc', COALESCE(p_buyer_email_cc, ''),
          'phone', COALESCE(p_buyer_phone, ''),
          'buyer_id', COALESCE(p_buyer_id, ''),
          'source', 'red_invoice_intake'
        )
        ELSE jsonb_build_object(
          'customer_name', 'Red invoice information pending',
          'source', p_source,
          'source_note', COALESCE(p_source_note, '')
        )
      END,
      status = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'manual_action_required'
        WHEN status IN ('pending', 'pending_manual_config')
          THEN 'dispatch_paused'
        ELSE status
      END,
      manual_action_type = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'buyer_info_after_issue'
        ELSE manual_action_type
      END,
      manual_action_note = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'Registered-buyer information arrived after first issuance. Review in MISA before any replacement or adjustment.'
        ELSE manual_action_note
      END,
      updated_at = now()
    WHERE id = v_job.id;
  END IF;

  IF v_complete_buyer AND COALESCE(btrim(p_buyer_tax_code), '') <> '' THEN
    INSERT INTO public.b2b_buyer_cache (
      store_id, buyer_tax_code, buyer_unit_code, tax_company_name,
      tax_address, tax_buyer_name, buyer_full_name, buyer_id, buyer_phone,
      receiver_email, receiver_email_cc, first_used_at, last_used_at,
      use_count, tax_entity_id
    ) VALUES (
      p_store_id, btrim(p_buyer_tax_code), NULLIF(btrim(p_buyer_unit_code), ''),
      NULLIF(btrim(p_buyer_legal_name), ''), NULLIF(btrim(p_buyer_address), ''),
      NULLIF(btrim(p_buyer_full_name), ''), NULLIF(btrim(p_buyer_full_name), ''),
      NULLIF(btrim(p_buyer_id), ''), NULLIF(btrim(p_buyer_phone), ''),
      btrim(p_buyer_email), NULLIF(btrim(p_buyer_email_cc), ''), now(), now(),
      1, v_tax_entity_id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      buyer_unit_code = EXCLUDED.buyer_unit_code,
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      tax_buyer_name = EXCLUDED.tax_buyer_name,
      buyer_full_name = EXCLUDED.buyer_full_name,
      buyer_id = EXCLUDED.buyer_id,
      buyer_phone = EXCLUDED.buyer_phone,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = public.b2b_buyer_cache.use_count + 1,
      tax_entity_id = EXCLUDED.tax_entity_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'upsert_red_invoice_intake', 'red_invoice_intakes', v_intake.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'source', p_source,
      'status', v_effective_status,
      'receipt_ids', to_jsonb(v_receipt_ids)
    )
  );

  RETURN to_jsonb(v_intake);
END;
$$;

CREATE OR REPLACE FUNCTION public.attach_red_invoice_intake_evidence(
  p_intake_id uuid,
  p_attachment_url text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_intake public.red_invoice_intakes%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN';
  END IF;
  IF COALESCE(btrim(p_attachment_url), '') = '' THEN
    RAISE EXCEPTION 'RED_INVOICE_ATTACHMENT_REQUIRED';
  END IF;

  SELECT * INTO v_intake
  FROM public.red_invoice_intakes
  WHERE id = p_intake_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_NOT_FOUND';
  END IF;
  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1 FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
       WHERE accessible.store_id = v_intake.store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  UPDATE public.red_invoice_intakes
  SET attachment_urls = CASE
        WHEN p_attachment_url = ANY(attachment_urls) THEN attachment_urls
        ELSE array_append(attachment_urls, p_attachment_url)
      END,
      updated_at = now(),
      updated_by = v_actor.id
  WHERE id = p_intake_id
  RETURNING * INTO v_intake;

  RETURN to_jsonb(v_intake);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_red_invoice_intakes(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_rows jsonb;
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION 'RED_INVOICE_DATE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.sale_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      intake.*,
      restaurant.name AS store_name,
      config.invoice_series,
      job.status AS meinvoice_status
    FROM public.red_invoice_intakes intake
    JOIN public.restaurants restaurant ON restaurant.id = intake.store_id
    LEFT JOIN public.meinvoice_tax_entity_config config
      ON config.tax_entity_id = intake.tax_entity_id
    LEFT JOIN public.meinvoice_jobs job ON job.id = intake.meinvoice_job_id
    WHERE (intake.sale_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date = p_business_date
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1 FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
          WHERE accessible.store_id = intake.store_id
        )
      )
  ) row_data;

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'requests', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_red_invoice_daily_export(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_finalization public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_rows jsonb;
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION 'RED_INVOICE_DATE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'RED_INVOICE_EXPORT_FORBIDDEN';
  END IF;

  SELECT * INTO v_finalization
  FROM public.restaurant_daily_sales_finalizations
  WHERE business_date = p_business_date;

  IF NOT FOUND OR v_finalization.status <> 'finalized' THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'status', 'pending',
      'requests', '[]'::jsonb
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.red_invoice_intakes intake
    LEFT JOIN public.meinvoice_tax_entity_config config
      ON config.tax_entity_id = intake.tax_entity_id
    WHERE (intake.sale_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date =
          p_business_date
      AND intake.status = 'ready'
      AND COALESCE(btrim(config.invoice_series), '') = ''
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_MISA_CONFIG_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.sale_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      intake.*,
      restaurant.name AS store_name,
      config.invoice_series,
      job.status AS meinvoice_status
    FROM public.red_invoice_intakes intake
    JOIN public.restaurants restaurant ON restaurant.id = intake.store_id
    LEFT JOIN public.meinvoice_tax_entity_config config
      ON config.tax_entity_id = intake.tax_entity_id
    LEFT JOIN public.meinvoice_jobs job ON job.id = intake.meinvoice_job_id
    WHERE (intake.sale_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date = p_business_date
      AND intake.status = 'ready'
  ) row_data;

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'status', 'finalized',
    'finalized_at', v_finalization.finalized_at,
    'request_count', jsonb_array_length(v_rows),
    'requests', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_red_invoice_intakes_exported(
  p_intake_ids uuid[],
  p_export_batch_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_count integer;
  v_actor_id uuid;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'RED_INVOICE_EXPORT_FORBIDDEN';
  END IF;
  IF p_export_batch_id IS NULL OR cardinality(COALESCE(p_intake_ids, ARRAY[]::uuid[])) = 0 THEN
    RAISE EXCEPTION 'RED_INVOICE_EXPORT_INVALID';
  END IF;

  SELECT id INTO v_actor_id
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  UPDATE public.red_invoice_intakes
  SET status = 'exported',
      exported_at = now(),
      export_batch_id = p_export_batch_id,
      updated_at = now(),
      updated_by = v_actor_id
  WHERE id = ANY(p_intake_ids)
    AND status = 'ready';
  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count <> cardinality(p_intake_ids) THEN
    RAISE EXCEPTION 'RED_INVOICE_EXPORT_STATE_CHANGED';
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'export_red_invoice_batch', 'red_invoice_intakes', NULL,
    jsonb_build_object(
      'export_batch_id', p_export_batch_id,
      'requested_count', cardinality(p_intake_ids),
      'exported_count', v_count,
      'intake_ids', to_jsonb(p_intake_ids)
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'export_batch_id', p_export_batch_id,
    'exported_count', v_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_red_invoice_intake(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text,
  text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_red_invoice_intake(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text,
  text, text
) TO authenticated;

REVOKE ALL ON FUNCTION public.attach_red_invoice_intake_evidence(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attach_red_invoice_intake_evidence(uuid, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.list_red_invoice_intakes(date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_red_invoice_intakes(date)
  TO authenticated;

REVOKE ALL ON FUNCTION public.get_red_invoice_daily_export(date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_red_invoice_daily_export(date)
  TO authenticated;

REVOKE ALL ON FUNCTION public.mark_red_invoice_intakes_exported(uuid[], uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_red_invoice_intakes_exported(uuid[], uuid)
  TO authenticated;

COMMIT;
