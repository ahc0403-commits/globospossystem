BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
-- Invoice descriptions and units only: no VAT master or monetary snapshot changes.
CREATE TABLE public.menu_invoice_profiles(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),menu_item_id uuid NOT NULL REFERENCES public.menu_items(id),
 invoice_name_vi text NOT NULL CHECK(length(btrim(invoice_name_vi)) BETWEEN 1 AND 200),
 unit_name text NOT NULL CHECK(length(btrim(unit_name)) BETWEEN 1 AND 40),
 effective_from timestamptz NOT NULL,effective_to timestamptz,
 approved_by uuid NOT NULL DEFAULT auth.uid(),approved_at timestamptz NOT NULL DEFAULT now(),
 CHECK(effective_to IS NULL OR effective_to>effective_from)
);
CREATE UNIQUE INDEX menu_invoice_profile_one_active ON public.menu_invoice_profiles(menu_item_id) WHERE effective_to IS NULL;
CREATE INDEX menu_invoice_profile_history ON public.menu_invoice_profiles(menu_item_id,effective_from DESC);
ALTER TABLE public.menu_invoice_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.menu_invoice_profiles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.menu_invoice_profiles TO authenticated;
CREATE POLICY menu_invoice_profiles_read ON public.menu_invoice_profiles FOR SELECT TO authenticated USING(public.is_super_admin()
 OR EXISTS(SELECT 1 FROM public.menu_items m JOIN public.user_accessible_stores(auth.uid()) s(store_id) ON s.store_id=m.restaurant_id WHERE m.id=menu_item_id));
ALTER TABLE public.menu_items ADD COLUMN invoice_name_vi text,ADD COLUMN invoice_unit_name text;
CREATE FUNCTION public.approve_menu_invoice_profile(p_menu_item_id uuid,p_name text,p_unit text,p_effective_from timestamptz DEFAULT now()) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE started timestamptz;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 PERFORM 1 FROM public.menu_items WHERE id=p_menu_item_id FOR UPDATE;
 IF NOT FOUND OR p_effective_from IS NULL OR p_effective_from>now() THEN RAISE EXCEPTION 'INVOICE_PROFILE_INVALID'; END IF;
 SELECT effective_from INTO started FROM public.menu_invoice_profiles WHERE menu_item_id=p_menu_item_id AND effective_to IS NULL;
 IF started IS NOT NULL AND p_effective_from<=started THEN RAISE EXCEPTION 'INVOICE_PROFILE_HISTORY_OVERLAP'; END IF;
 UPDATE public.menu_invoice_profiles SET effective_to=p_effective_from WHERE menu_item_id=p_menu_item_id AND effective_to IS NULL;
 INSERT INTO public.menu_invoice_profiles(menu_item_id,invoice_name_vi,unit_name,effective_from)
 VALUES(p_menu_item_id,btrim(p_name),btrim(p_unit),p_effective_from);
 UPDATE public.menu_items SET invoice_name_vi=btrim(p_name),invoice_unit_name=btrim(p_unit) WHERE id=p_menu_item_id;
END $$;
REVOKE ALL ON FUNCTION public.approve_menu_invoice_profile(uuid,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_menu_invoice_profile(uuid,text,text,timestamptz) TO authenticated;
CREATE FUNCTION public.misa_payment_code_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value),
 labels AS(SELECT DISTINCT CASE method WHEN 'CASH' THEN 'TM' WHEN 'BANKTRANSFER' THEN 'CK'
 WHEN 'CREDITCARD' THEN 'Thẻ quốc tế' WHEN 'ATM' THEN 'Thẻ ATM' ELSE 'Ví điện tử' END label FROM methods)
 SELECT CASE WHEN count(*)=0 OR bool_or(method NOT IN('CASH','BANKTRANSFER','CREDITCARD','ATM','OTHER','EPAY','PAY')) THEN 'UNMAPPED'
 WHEN count(*)=2 AND bool_and(method IN('CASH','BANKTRANSFER')) THEN 'TM/CK'
 ELSE (SELECT string_agg(label,'/' ORDER BY label COLLATE "C") FROM labels) END FROM methods;
$$;
CREATE OR REPLACE FUNCTION public.meinvoice_payment_method_label(p_tax_entity_id uuid,p_methods text[]) RETURNS text
 LANGUAGE sql STABLE SET search_path=public,pg_catalog AS $$ SELECT public.misa_payment_code_for_methods(p_methods); $$;
ALTER TABLE public.meinvoice_jobs ADD COLUMN snapshot_version integer NOT NULL DEFAULT 1;
ALTER TABLE public.meinvoice_jobs ALTER COLUMN snapshot_version SET DEFAULT 2;
CREATE TABLE public.meinvoice_job_snapshot_versions(
 job_id uuid NOT NULL REFERENCES public.meinvoice_jobs(id),snapshot_version integer NOT NULL,
 payment_method_snapshot text NOT NULL,line_items_snapshot jsonb NOT NULL,payment_summary jsonb NOT NULL,
 source_hash text NOT NULL,captured_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(job_id,snapshot_version)
);
ALTER TABLE public.meinvoice_job_snapshot_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meinvoice_job_snapshot_versions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.meinvoice_job_snapshot_versions TO authenticated;
CREATE POLICY invoice_versions_read ON public.meinvoice_job_snapshot_versions FOR SELECT TO authenticated USING(public.is_super_admin());
CREATE FUNCTION public.preserve_meinvoice_export_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF OLD.payment_method_snapshot IS NOT DISTINCT FROM NEW.payment_method_snapshot AND OLD.line_items_snapshot IS NOT DISTINCT FROM NEW.line_items_snapshot AND OLD.payment_summary IS NOT DISTINCT FROM NEW.payment_summary THEN RETURN NEW; END IF;
 IF OLD.status IN('sent_to_misa','sent_to_tax_authority','valid_invoice','resolved') OR OLD.misa_ref_id IS NOT NULL OR OLD.invoice_number IS NOT NULL OR OLD.dispatch_claim_id IS NOT NULL OR COALESCE(OLD.dispatch_attempts,0)>0 THEN RAISE EXCEPTION 'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE'; END IF;
 INSERT INTO public.meinvoice_job_snapshot_versions(job_id,snapshot_version,payment_method_snapshot,line_items_snapshot,payment_summary,source_hash)
 VALUES(OLD.id,OLD.snapshot_version,OLD.payment_method_snapshot,OLD.line_items_snapshot,OLD.payment_summary,
 md5(jsonb_build_object('method',OLD.payment_method_snapshot,'items',OLD.line_items_snapshot,'payments',OLD.payment_summary)::text)) ON CONFLICT DO NOTHING;
 NEW.snapshot_version:=OLD.snapshot_version+1; RETURN NEW;
END $$;
CREATE TRIGGER preserve_meinvoice_export_snapshot BEFORE UPDATE ON public.meinvoice_jobs FOR EACH ROW EXECUTE FUNCTION public.preserve_meinvoice_export_snapshot();
CREATE FUNCTION public.pos_restaurant_receipt_rows_v2(p_business_date date,p_order_ids uuid[] DEFAULT NULL)
RETURNS TABLE(tax_entity_id uuid,seller_tax_code text,seller_legal_name text,is_sample_entity boolean,receipt_id text,store_id uuid,
 store_name text,receipt_source text,source_system text,sales_channel text,sold_at timestamptz,gross_sales numeric,payment_method text,
 is_red_invoice boolean,red_invoice_status text,buyer_tax_code text,buyer_legal_name text,buyer_address text,buyer_email text,buyer_phone text,line_items jsonb,receipt_number text,payment_methods text[],snapshot_version integer,source_hash text,payment_code text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $rows$
  WITH candidates AS MATERIALIZED(
    SELECT DISTINCT payment.order_id FROM public.payments payment
    WHERE payment.is_revenue AND payment.created_at >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh') AND payment.created_at < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
      AND (p_order_ids IS NULL OR payment.order_id=ANY(p_order_ids))
  ), paid_orders AS MATERIALIZED (
    SELECT
      payment.order_id,
      payment.restaurant_id AS store_id,
      max(payment.created_at) AS sold_at,
      round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
        AS gross_sales,
      array_agg(DISTINCT payment.method ORDER BY payment.method)
        AS payment_methods
    FROM public.payments payment JOIN candidates scope ON scope.order_id=payment.order_id
    JOIN public.orders issued_order
      ON issued_order.id = payment.order_id
     AND issued_order.status = 'completed'
    JOIN public.restaurants restaurant
      ON restaurant.id = payment.restaurant_id
     AND restaurant.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
    WHERE payment.is_revenue = true
      AND restaurant.id <> '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
      AND restaurant.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
    GROUP BY payment.order_id, payment.restaurant_id
    HAVING max(payment.created_at) >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
       AND max(payment.created_at) < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ),
  latest_jobs AS MATERIALIZED (
    SELECT DISTINCT ON(candidate.order_id) candidate.order_id,candidate.tax_entity_id,candidate.payment_method_snapshot,candidate.line_items_snapshot,candidate.snapshot_version
    FROM public.meinvoice_jobs candidate JOIN paid_orders scope ON scope.order_id=candidate.order_id
    WHERE candidate.source_system='restaurant_pos' ORDER BY candidate.order_id,candidate.created_at DESC,candidate.id DESC
  ), historical_entities AS MATERIALIZED (
    SELECT DISTINCT ON(scope.order_id) scope.order_id,history.tax_entity_id
    FROM paid_orders scope JOIN public.store_tax_entity_history history ON history.store_id=scope.store_id
    AND history.effective_from<=scope.sold_at AND (history.effective_to IS NULL OR scope.sold_at<history.effective_to)
    ORDER BY scope.order_id,history.effective_from DESC,history.created_at DESC
  ), approved_profiles AS MATERIALIZED (
    SELECT DISTINCT ON(item.id) item.id,profile.id profile_id,profile.invoice_name_vi,profile.unit_name
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=item.menu_item_id
      AND profile.effective_from<=scope.sold_at AND (profile.effective_to IS NULL OR scope.sold_at<profile.effective_to)
    ORDER BY item.id,profile.effective_from DESC,profile.id DESC
  ), order_lines AS MATERIALIZED (
    SELECT item.order_id,jsonb_agg(jsonb_build_object(
      'order_item_id',CASE WHEN item.vat_rate=-1 THEN item.id::text||':'||(part->>'vat_rate') ELSE item.id::text END,
      'menu_item_id',item.menu_item_id,'invoice_profile_id',profile.profile_id,
      'display_name',COALESCE(NULLIF(item.display_name,''),NULLIF(item.label,''),'Món ăn'),
      'invoice_name_vi',profile.invoice_name_vi,'misa_unit_name',profile.unit_name,
      'item_type',item.item_type,'quantity',CASE WHEN item.vat_rate=-1 THEN 1 ELSE item.quantity END,
      'misa_unit_price',(part->>'total_amount_ex_tax')::numeric/NULLIF(CASE WHEN item.vat_rate=-1 THEN 1 ELSE item.quantity END,0), 'misa_discount_amount',0,
      'unit_price',CASE WHEN item.vat_rate=-1 THEN (part->>'total_amount_ex_tax')::numeric ELSE item.unit_price END,
      'total_amount_ex_tax',(part->>'total_amount_ex_tax')::numeric,
      'vat_rate',(part->>'vat_rate')::numeric,'vat_amount',(part->>'vat_amount')::numeric,
      'paying_amount_inc_tax',COALESCE((part->>'paying_amount_inc_tax')::numeric,(part->>'total_amount_ex_tax')::numeric+(part->>'vat_amount')::numeric)) ORDER BY item.created_at,item.id,part->>'vat_rate') line_items
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    LEFT JOIN approved_profiles profile ON profile.id=item.id
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN item.vat_rate=-1 THEN item.vat_breakdown
      ELSE jsonb_build_array(jsonb_build_object('vat_rate',item.vat_rate,'vat_amount',item.vat_amount,
        'total_amount_ex_tax',item.total_amount_ex_tax,'paying_amount_inc_tax',item.paying_amount_inc_tax)) END) part
    WHERE item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false GROUP BY item.order_id
  ), receipt_candidates AS MATERIALIZED(
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope
    JOIN public.digital_receipts d ON d.order_id=scope.order_id AND d.restaurant_id=scope.store_id
    UNION ALL
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope JOIN public.payments p ON p.order_id=scope.order_id AND p.restaurant_id=scope.store_id AND p.is_revenue
    JOIN public.digital_receipts d ON d.combined_payment_group_id=p.combined_payment_group_id AND d.order_id IS NULL AND d.restaurant_id=scope.store_id
  ), receipt_numbers AS MATERIALIZED(
    SELECT DISTINCT ON(order_id) order_id,receipt_number FROM receipt_candidates ORDER BY order_id,created_at DESC,id DESC
  ), report_rows AS (
    SELECT
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      seller.id = '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid AS is_sample_entity,
      paid.order_id::text AS receipt_id,
      paid.store_id,
      restaurant.name AS store_name,
      'pos_payment'::text AS receipt_source,
      'restaurant_pos'::text AS source_system,
      orders.sales_channel,
      paid.sold_at,
      paid.gross_sales,
      public.misa_payment_code_for_methods(paid.payment_methods) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(intake.buyer_email, '') AS buyer_email,
      COALESCE(intake.buyer_phone, '') AS buyer_phone,
      COALESCE(CASE WHEN job.snapshot_version>=2 THEN NULLIF(job.line_items_snapshot,'[]'::jsonb) END,
        order_lines.line_items,'[]'::jsonb) AS line_items,
      COALESCE(receipt_number.receipt_number,'POS-'||upper(substr(replace(paid.order_id::text,'-',''),1,10))) AS receipt_number,
      paid.payment_methods,COALESCE(job.snapshot_version,1),
      md5(jsonb_build_object('order_id',paid.order_id,'gross',paid.gross_sales,'methods',paid.payment_methods,
        'items',COALESCE(CASE WHEN job.snapshot_version>=2 THEN NULLIF(job.line_items_snapshot,'[]'::jsonb) END,order_lines.line_items,'[]'::jsonb))::text) AS source_hash,
      CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code
    FROM paid_orders paid
    JOIN public.orders orders ON orders.id = paid.order_id
    JOIN public.restaurants restaurant ON restaurant.id = paid.store_id
    LEFT JOIN public.red_invoice_intakes intake
      ON intake.order_id = paid.order_id
    LEFT JOIN latest_jobs job ON job.order_id=paid.order_id
    LEFT JOIN historical_entities historical_entity ON historical_entity.order_id=paid.order_id
    JOIN public.tax_entity seller
      ON seller.id = CASE
        WHEN paid.store_id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid THEN restaurant.tax_entity_id
        ELSE COALESCE(
          job.tax_entity_id,
          historical_entity.tax_entity_id,
          restaurant.tax_entity_id
        )
      END
    LEFT JOIN public.meinvoice_tax_entity_config config ON config.tax_entity_id=seller.id
    LEFT JOIN receipt_numbers receipt_number ON receipt_number.order_id=paid.order_id
    LEFT JOIN order_lines ON order_lines.order_id=paid.order_id
    WHERE seller.id <> '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
  ) SELECT * FROM report_rows;

$rows$;
REVOKE ALL ON FUNCTION public.pos_restaurant_receipt_rows_v2(date,uuid[]) FROM PUBLIC,anon,authenticated;
DO $report$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 IF strpos(d,'public.pos_restaurant_receipt_rows(')=0 THEN RAISE EXCEPTION 'INVOICE_EXPORT_REPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE replace(d,'public.pos_restaurant_receipt_rows(','public.pos_restaurant_receipt_rows_v2(');
END $report$;
CREATE FUNCTION public.refresh_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_tax_entity_id IS NULL OR cardinality(p_order_ids) NOT BETWEEN 1 AND 100
 OR p_order_ids IS NULL OR EXISTS(SELECT 1 FROM unnest(p_order_ids) x WHERE x IS NULL) OR cardinality(p_order_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_order_ids) x) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_INVALID'; END IF;
 SELECT count(*) INTO n FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id;
 IF n<>cardinality(p_order_ids) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_CHANGED'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id),
 updated AS(UPDATE public.meinvoice_jobs j SET payment_method_snapshot=s.payment_method,line_items_snapshot=s.line_items,updated_at=now()
 FROM scope s WHERE j.order_id::text=s.receipt_id AND j.tax_entity_id=p_tax_entity_id AND j.status IN('pending_manual_config','dispatch_paused','pending')
 AND j.dispatch_claim_id IS NULL AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL AND COALESCE(j.dispatch_attempts,0)=0
 AND s.payment_method<>'UNMAPPED' AND jsonb_array_length(s.line_items)>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s.line_items) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='')
 RETURNING j.id) SELECT count(*) INTO n FROM updated;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) TO authenticated;
DO $enqueue$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure) INTO d;
 IF strpos(d,'''item_type'', oi.item_type,')=0 OR strpos(d,'  WHERE oi.order_id = NEW.id')=0 THEN RAISE EXCEPTION 'INVOICE_ENQUEUE_ANCHOR_CHANGED'; END IF;
 d:=replace(d,$old$'item_type', oi.item_type,$old$,$new$'menu_item_id', oi.menu_item_id, 'invoice_profile_id', profile.id, 'misa_unit_price', tax_line.total_amount_ex_tax/NULLIF(tax_line.quantity,0), 'misa_discount_amount', 0, 'invoice_name_vi', profile.invoice_name_vi, 'misa_unit_name', profile.unit_name, 'item_type', oi.item_type,$new$);
 d:=replace(d,'  WHERE oi.order_id = NEW.id',E'  LEFT JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=oi.menu_item_id AND profile.effective_from<=now() AND (profile.effective_to IS NULL OR now()<profile.effective_to)\n  WHERE oi.order_id = NEW.id');
 EXECUTE d;
 SELECT pg_get_functiondef('public.claim_meinvoice_jobs(uuid,integer,uuid)'::regprocedure) INTO d;
 IF strpos(d,'status=''pending'' AND dispatch_claim_id IS NULL')=0 THEN RAISE EXCEPTION 'INVOICE_CLAIM_ANCHOR_CHANGED'; END IF;
 EXECUTE replace(d,$old$status='pending' AND dispatch_claim_id IS NULL$old$,$new$status='pending' AND dispatch_claim_id IS NULL AND (source_system='photo_objet_moers' OR (snapshot_version>=2 AND payment_method_snapshot<>'UNMAPPED' AND payment_method_snapshot NOT LIKE '%QR%' AND jsonb_array_length(line_items_snapshot)>0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(line_items_snapshot) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='' OR COALESCE(line->>'order_item_id','')='')))$new$);
END $enqueue$;
DO $verify$ BEGIN
 IF public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['CASH','BANKTRANSFER'])<>'TM/CK'
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'INVOICE_EXPORT_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
