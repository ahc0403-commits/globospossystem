SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
CREATE FUNCTION public.user_accessible_stores(uuid) RETURNS SETOF uuid LANGUAGE sql AS $$ SELECT id FROM public.restaurants $$;
ALTER TABLE restaurants ADD COLUMN is_active boolean DEFAULT true;
CREATE TABLE menu_items(id uuid PRIMARY KEY,restaurant_id uuid,name text,vat_rate numeric);
ALTER TABLE order_items ADD COLUMN menu_item_id uuid, ADD COLUMN paying_amount_inc_tax numeric, ADD COLUMN vat_breakdown jsonb;
ALTER TABLE meinvoice_jobs ADD PRIMARY KEY(id), ADD COLUMN status text DEFAULT 'pending', ADD COLUMN misa_ref_id text, ADD COLUMN invoice_number text, ADD COLUMN dispatch_claim_id uuid, ADD COLUMN dispatch_attempts integer DEFAULT 0, ADD COLUMN updated_at timestamptz, ADD COLUMN payment_summary jsonb DEFAULT '{}'::jsonb, ADD COLUMN buyer_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE TABLE direct_order_storefronts(restaurant_id uuid PRIMARY KEY,bank_bin text,bank_label text,bank_account_number text,bank_account_holder text,accounting_approved_at timestamptz,created_by uuid,updated_by uuid,accounting_approved_by uuid);
CREATE TABLE direct_order_sessions(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,restaurant_id uuid);
CREATE TABLE customer_payment_displays(store_id uuid PRIMARY KEY,order_id uuid,status text,payload jsonb);
CREATE FUNCTION direct_order_require_actor(uuid,text[]) RETURNS void LANGUAGE sql AS $$ SELECT $$;
CREATE FUNCTION direct_order_public_resume_storefront(uuid,text) RETURNS jsonb LANGUAGE plpgsql AS $$ DECLARE v_session public.direct_order_sessions;v_result jsonb;BEGIN SELECT * INTO v_session FROM direct_order_sessions WHERE id=$1;v_result:='{}'; RETURN v_result;END $$;
CREATE TABLE photo_objet_sales_raw(source_hash text PRIMARY KEY,store_id uuid,sold_at timestamptz,amount numeric,sale_date date,source_identity_version integer,device_name text);
CREATE TABLE photo_objet_sales_pull_runs(store_id uuid,target_date date,collector_method text,status text);
CREATE TABLE daily_closings(restaurant_id uuid,closing_date date,close_source text,counted_cash_amount numeric,opening_cash_amount numeric,cash_variance numeric,direct_order_cash_refunds numeric,delivery_cash_paid numeric,delivery_cash_recovered numeric);
-- The migration patches these interfaces. VAT behavior is separately covered by the actual beverage migration suite.
CREATE FUNCTION enqueue_meinvoice_cash_register_job() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE items jsonb; BEGIN
 SELECT jsonb_agg(jsonb_build_object('order_item_id',oi.id,'item_type', oi.item_type,'quantity',oi.quantity,'vat_rate',oi.vat_rate)) INTO items
 FROM public.order_items oi
 CROSS JOIN LATERAL (SELECT oi.total_amount_ex_tax,oi.quantity) tax_line
  WHERE oi.order_id = NEW.id;
 RETURN NEW;END $$;
ALTER TABLE public.meinvoice_jobs ADD COLUMN manual_action_type text,ADD COLUMN error_message text,ADD COLUMN last_dispatch_at timestamptz,ADD COLUMN sent_at timestamptz,ADD COLUMN transaction_id text,ADD COLUMN invoice_series text,ADD COLUMN tax_authority_code text,ADD COLUMN search_code text;
CREATE TABLE public.meinvoice_job_events(job_id uuid,event_type text,description text,retry_count integer,metadata jsonb DEFAULT '{}');
INSERT INTO tax_entity VALUES('a6bda671-4179-5a29-a798-76357b42b497','AKJ-FIXTURE','AKJ INTERNATIONAL CO., LTD');
INSERT INTO restaurants(id,name,tax_entity_id) VALUES('20000000-0000-0000-0000-000000000099','AKJ restaurant','a6bda671-4179-5a29-a798-76357b42b497');
INSERT INTO direct_order_storefronts(restaurant_id,bank_bin,bank_label,bank_account_number,bank_account_holder) VALUES('20000000-0000-0000-0000-000000000099','970457','Legacy','100202042976','Legacy holder');
INSERT INTO direct_order_sessions VALUES('90000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000099');
CREATE OR REPLACE FUNCTION public.get_photo_sales_misa_exports_by_tax_entity(
  p_business_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_business_date date := p_business_date;
  v_hcm_today date := (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_entities jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_FORBIDDEN';
  END IF;
  IF v_business_date IS NULL
     OR v_business_date < DATE '2020-01-01'
     OR v_business_date > v_hcm_today THEN
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_DATE_INVALID';
  END IF;

  WITH photo_rows AS (
    SELECT
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      raw.source_hash,
      raw.store_id,
      store.name AS store_name,
      raw.device_name,
      raw.sold_at,
      raw.amount
    FROM public.photo_objet_sales_raw raw
    JOIN public.restaurants store
      ON store.id = raw.store_id
     AND store.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    JOIN public.tax_entity seller
      ON seller.id = coalesce(
        (
          SELECT history.tax_entity_id
          FROM public.store_tax_entity_history history
          WHERE history.store_id = raw.store_id
            AND history.effective_from <= raw.sold_at
            AND (
              history.effective_to IS NULL
              OR raw.sold_at < history.effective_to
            )
          ORDER BY history.effective_from DESC, history.created_at DESC
          LIMIT 1
        ),
        store.tax_entity_id
      )
    WHERE raw.sale_date = v_business_date
      AND raw.source_identity_version = 2
      AND raw.amount > 0
  ),
  entity_rollups AS (
    SELECT
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name,
      count(DISTINCT rows.store_id)::integer AS store_count,
      count(*)::integer AS receipt_count,
      sum(rows.amount)::bigint AS gross_sales,
      jsonb_agg(
        jsonb_build_object(
          'source_hash', rows.source_hash,
          'store_id', rows.store_id,
          'store_name', rows.store_name,
          'device_name', rows.device_name,
          'sold_at', rows.sold_at,
          'amount', rows.amount
        )
        ORDER BY rows.sold_at, rows.source_hash
      ) AS receipts
    FROM photo_rows rows
    GROUP BY
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tax_entity_id', rollup.tax_entity_id,
        'seller_tax_code', rollup.seller_tax_code,
        'seller_legal_name', rollup.seller_legal_name,
        'store_count', rollup.store_count,
        'receipt_count', rollup.receipt_count,
        'gross_sales', rollup.gross_sales,
        'receipts', rollup.receipts
      )
      ORDER BY rollup.seller_tax_code, rollup.tax_entity_id
    ),
    '[]'::jsonb
  )
  INTO v_entities
  FROM entity_rollups rollup;

  RETURN jsonb_build_object(
    'business_date', v_business_date,
    'entity_count', jsonb_array_length(v_entities),
    'entities', v_entities
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_admin_get_storefront(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_row public.direct_order_storefronts%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT * INTO v_row
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'restaurant_id', p_store_id,
      'is_enabled', false,
      'is_paused', false,
      'accounting_approved', false
    );
  END IF;
  RETURN (
    to_jsonb(v_row) - ARRAY[
      'created_by', 'updated_by', 'accounting_approved_by'
    ]
  ) || jsonb_build_object(
    'accounting_approved', v_row.accounting_approved_at IS NOT NULL
  );
END;
$$;
