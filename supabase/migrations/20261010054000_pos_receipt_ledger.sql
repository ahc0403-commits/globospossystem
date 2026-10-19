-- POS ledger reads reuse the existing report scope. No external invoice API.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE FUNCTION public.pos_restaurant_receipt_rows(p_business_date date,p_order_ids uuid[] DEFAULT NULL)
RETURNS TABLE(tax_entity_id uuid,seller_tax_code text,seller_legal_name text,is_sample_entity boolean,receipt_id text,store_id uuid,
 store_name text,receipt_source text,source_system text,sales_channel text,sold_at timestamptz,gross_sales numeric,payment_method text,
 is_red_invoice boolean,red_invoice_status text,buyer_tax_code text,buyer_legal_name text,buyer_address text,buyer_email text,buyer_phone text,line_items jsonb,receipt_number text)
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
    SELECT DISTINCT ON(candidate.order_id) candidate.order_id,candidate.tax_entity_id,candidate.payment_method_snapshot,candidate.line_items_snapshot
    FROM public.meinvoice_jobs candidate JOIN paid_orders scope ON scope.order_id=candidate.order_id
    WHERE candidate.source_system='restaurant_pos' ORDER BY candidate.order_id,candidate.created_at DESC,candidate.id DESC
  ), historical_entities AS MATERIALIZED (
    SELECT DISTINCT ON(scope.order_id) scope.order_id,history.tax_entity_id
    FROM paid_orders scope JOIN public.store_tax_entity_history history ON history.store_id=scope.store_id
    AND history.effective_from<=scope.sold_at AND (history.effective_to IS NULL OR scope.sold_at<history.effective_to)
    ORDER BY scope.order_id,history.effective_from DESC,history.created_at DESC
  ), order_lines AS MATERIALIZED (
    SELECT item.order_id,jsonb_agg(jsonb_build_object('display_name',COALESCE(NULLIF(item.display_name,''),NULLIF(item.label,''),'Món ăn'),
    'item_type',item.item_type,'quantity',item.quantity,'unit_price',item.unit_price,'total_amount_ex_tax',item.total_amount_ex_tax,
    'vat_rate',item.vat_rate,'vat_amount',item.vat_amount) ORDER BY item.created_at,item.id) line_items
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
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
      COALESCE(
        NULLIF(btrim(job.payment_method_snapshot), ''),
        CASE WHEN cardinality(paid.payment_methods)<>1 THEN COALESCE(config.payment_method_mixed,'Tiền mặt/Thẻ/Ví điện tử')
        WHEN paid.payment_methods[1]='CASH' THEN COALESCE(config.payment_method_cash,'Tiền mặt')
        WHEN paid.payment_methods[1] IN ('CREDITCARD','ATM') THEN COALESCE(config.payment_method_card,'Thẻ quốc tế')
        ELSE COALESCE(config.payment_method_pay,'Ví điện tử/QR') END
      ) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(intake.buyer_email, '') AS buyer_email,
      COALESCE(intake.buyer_phone, '') AS buyer_phone,
      COALESCE(
        NULLIF(job.line_items_snapshot, '[]'::jsonb),
        order_lines.line_items,
        '[]'::jsonb
      ) AS line_items,
      COALESCE(receipt_number.receipt_number,'POS-'||upper(substr(replace(paid.order_id::text,'-',''),1,10))) AS receipt_number
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
REVOKE ALL ON FUNCTION public.pos_restaurant_receipt_rows(date,uuid[]) FROM PUBLIC,anon,authenticated;
DO $patch$
DECLARE d text;start_at integer;end_at integer;
BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 start_at:=strpos(d,'  WITH paid_orders AS (');end_at:=strpos(d,'  entity_rollups AS (');
 IF start_at=0 OR end_at<=start_at OR strpos(d,'IF p_business_date > v_hcm_now::date THEN')=0 OR strpos(d,'''item_type'', item.item_type')=0 THEN RAISE EXCEPTION 'POS_LEDGER_REPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE substr(d,1,start_at-1)||'  WITH report_rows AS (SELECT * FROM public.pos_restaurant_receipt_rows(p_business_date)),
'||substr(d,end_at);
END; $patch$;

CREATE FUNCTION public.pos_receipt_ledger_batch(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[],p_red boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF $1 IS NULL OR $1>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR $2 IS NULL OR $4 IS NULL
 OR $3 IS NULL OR cardinality($3) NOT BETWEEN 1 AND 50 OR EXISTS(SELECT 1 FROM unnest($3) x WHERE x IS NULL)
 OR cardinality($3)<>(SELECT count(DISTINCT x) FROM unnest($3) x) THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_INVALID'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows($1,$3) r WHERE r.tax_entity_id=$2 AND r.is_red_invoice=$4),
 payment_rows AS(SELECT p.order_id,jsonb_agg(jsonb_build_object('payment_id',p.id,'method',p.method,'amount',COALESCE(p.amount_portion,p.amount),
 'paid_at',p.created_at) ORDER BY p.created_at,p.id) rows FROM public.payments p JOIN scope s ON s.receipt_id=p.order_id::text AND s.store_id=p.restaurant_id
 WHERE p.is_revenue GROUP BY p.order_id)
 SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object('order_id',s.receipt_id,'payments',p.rows,
 'buyer',CASE WHEN i.id IS NULL THEN NULL ELSE to_jsonb(i)-'meinvoice_job_id'-'export_batch_id'-'line_items_snapshot'-'receipt_ids'-'gross_amount'-'payment_method'-'tax_entity_id' END) ORDER BY s.sold_at,s.receipt_id),'[]'::jsonb)
 INTO n,v FROM scope s LEFT JOIN payment_rows p ON p.order_id::text=s.receipt_id LEFT JOIN public.red_invoice_intakes i ON i.order_id::text=s.receipt_id;
 IF n<>cardinality($3) THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_CHANGED'; END IF;
 RETURN jsonb_build_object('business_date',$1,'tax_entity_id',$2,'rows',v);
END; $$;
REVOKE ALL ON FUNCTION public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean) TO authenticated;
DO $verify$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 IF strpos(d,'LATERAL')<>0 OR strpos(d,'meinvoice_payment_method_label(')<>0 OR strpos(d,'is_super_admin()')=0
 OR strpos(d,'v_finalization.status')=0 OR has_function_privilege('anon','public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)','EXECUTE')
 THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_DRIFT'; END IF;
END; $verify$;
COMMIT;
