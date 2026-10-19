-- Document-led procurement contract. Existing requests retain their policy version.
BEGIN;
ALTER TABLE public.procurement_store_policies ADD COLUMN three_stage_required boolean NOT NULL DEFAULT false,ADD COLUMN new_requests_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE public.inventory_products
 ADD COLUMN specification text NOT NULL DEFAULT '',
 ADD COLUMN receipt_classification text NOT NULL DEFAULT 'stock' CHECK(receipt_classification IN ('stock','nonstock','asset'));
ALTER TABLE public.inventory_purchase_requests DROP CONSTRAINT inventory_purchase_requests_status_check;
ALTER TABLE public.inventory_purchase_requests
 ADD CONSTRAINT inventory_purchase_requests_status_check CHECK(status IN ('draft','submitted','brand_review','office_review','senior_review','approved','allocated','returned','cancelled')),
 ADD COLUMN approval_policy_version integer NOT NULL DEFAULT 1 CHECK(approval_policy_version IN (1,2)),
 ADD COLUMN purchase_category text NOT NULL DEFAULT 'raw_material' CHECK(purchase_category IN ('raw_material','tools','stationery','other')),
 ADD COLUMN purchase_channel text NOT NULL DEFAULT 'ordinary' CHECK(purchase_channel IN ('ordinary','shopee')),
 ADD COLUMN submitted_at timestamptz, ADD COLUMN store_approved_at timestamptz,
 ADD COLUMN brand_approved_actor jsonb, ADD COLUMN brand_approved_at timestamptz, ADD COLUMN brand_approval_hash text,
 ADD COLUMN office_approved_at timestamptz;
ALTER TABLE public.inventory_purchase_request_lines
 ADD COLUMN product_name_snapshot text, ADD COLUMN specification_snapshot text,
 ADD COLUMN receipt_classification text NOT NULL DEFAULT 'stock' CHECK(receipt_classification IN ('stock','nonstock','asset')),
 ADD COLUMN estimated_unit_price numeric(12,2), ADD COLUMN estimated_tax_rate numeric(5,2),
 ADD COLUMN estimated_conversion numeric(12,3), ADD COLUMN estimated_order_unit text,
 ADD COLUMN estimated_supplier_item_id uuid REFERENCES public.inventory_supplier_items(id);
ALTER TABLE public.inventory_purchase_order_lines ADD COLUMN receipt_classification_snapshot text NOT NULL DEFAULT 'stock'
 CHECK(receipt_classification_snapshot IN ('stock','nonstock','asset'));
ALTER TABLE public.inventory_receipt_lines ADD COLUMN expected_quantity_base_snapshot numeric(12,3);
CREATE TABLE public.procurement_document_exports(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 record_id uuid NOT NULL,kind text NOT NULL CHECK(kind IN ('pr','po')),audience text NOT NULL CHECK(audience IN ('internal','supplier')),
 source_hash text NOT NULL,storage_path text NOT NULL,sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
 size_bytes integer NOT NULL CHECK(size_bytes>0),status text NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','superseded')),
 generated_actor jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(record_id,kind,audience,source_hash,sha256)
);
ALTER TABLE public.procurement_document_exports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_document_exports FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_document_exports TO service_role;
CREATE INDEX procurement_request_lines_request ON public.inventory_purchase_request_lines(request_id) WHERE active;
CREATE INDEX procurement_quotes_request ON public.procurement_quotes(request_id) WHERE NOT archived;
CREATE INDEX procurement_receipt_lines_order ON public.inventory_receipt_lines(purchase_order_line_id);
CREATE INDEX procurement_events_store_page ON public.procurement_events(restaurant_id,created_at DESC,id);
CREATE INDEX procurement_returns_receipt_line ON public.inventory_supplier_returns(receipt_line_id);
CREATE INDEX procurement_orders_store_page ON public.inventory_purchase_orders(restaurant_id,created_at DESC,id) WHERE workflow_version=2;

-- Non-monetary Office status is mirrored through the scoped server bridge.
CREATE TABLE public.procurement_accounting_status(
 purchase_order_id uuid PRIMARY KEY REFERENCES public.inventory_purchase_orders(id),restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 source_order_version integer NOT NULL,invoice_count integer NOT NULL CHECK(invoice_count>=0),payable_count integer NOT NULL CHECK(payable_count>=0),
 held_count integer NOT NULL CHECK(held_count>=0),paid_count integer NOT NULL CHECK(paid_count>=0),reconciliation_required boolean NOT NULL,
 observed_at timestamptz NOT NULL
);
ALTER TABLE public.procurement_accounting_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_accounting_status FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_accounting_status TO service_role;
CREATE TABLE public.procurement_channel_payments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id),external_order_no text NOT NULL,
 kind text NOT NULL CHECK(kind IN ('advance','refund','reimbursement')),paid_by text NOT NULL CHECK(paid_by IN ('company','employee')),
 amount numeric(14,2) NOT NULL CHECK(amount>0 AND amount::text NOT IN ('NaN','Infinity','-Infinity')),
 payment_reference text NOT NULL CHECK(length(btrim(payment_reference))>0),evidence_reference text NOT NULL CHECK(length(btrim(evidence_reference))>0),
 actor jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(restaurant_id,kind,payment_reference)
);
ALTER TABLE public.procurement_channel_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_channel_payments FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_channel_payments TO service_role;
CREATE UNIQUE INDEX procurement_external_order_unique ON public.inventory_purchase_orders(restaurant_id,(commercial_terms->>'external_order_no')) WHERE commercial_terms ? 'external_order_no';
CREATE INDEX procurement_channel_payments_order ON public.procurement_channel_payments(purchase_order_id);
CREATE OR REPLACE FUNCTION public.procurement_actor(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; role_name text;
BEGIN
 IF auth.role()='service_role' THEN
   IF p_office_actor IS NULL OR COALESCE(p_office_actor->>'system','') NOT IN ('office','scheduled')
     OR NULLIF(p_office_actor->>'subject_id','') IS NULL
     OR p_office_actor->>'store_id' IS DISTINCT FROM p_store_id::text THEN
     RAISE EXCEPTION 'PROCUREMENT_OFFICE_ACTOR_REQUIRED'; END IF;
   RETURN p_office_actor;
 END IF;
 IF p_office_actor IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_ACTOR_FORBIDDEN'; END IF;
 IF NOT public.can_access_inventory_workflow(p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 role_name:=public.inventory_purchase_actor_role();
 RETURN jsonb_build_object('system','pos','subject_id',auth.uid(),'store_id',p_store_id,'role',role_name,'display_name',(SELECT full_name FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1),
 'can_create',role_name IN ('inventory_orderer','admin','store_admin','brand_admin','super_admin'),
 'can_store_approve',role_name IN ('admin','store_admin','brand_admin','super_admin'),
 'can_brand_approve',role_name IN ('brand_admin','super_admin'),'can_office_approve',false,'can_senior_approve',false,'can_manage',role_name='super_admin',
 'can_view_prices',role_name<>'inventory_orderer');
END $$;
REVOKE ALL ON FUNCTION public.procurement_actor(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.procurement_commercial_coverage(p_request_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 WITH quoted AS (SELECT ql.request_line_id,sum(ql.quantity_base) qty FROM public.procurement_quote_lines ql
 JOIN public.procurement_quotes q ON q.id=ql.quote_id WHERE q.request_id=p_request_id AND q.selected AND NOT q.archived GROUP BY ql.request_line_id)
 SELECT count(*)>0 AND bool_and(l.quantity_base=COALESCE(q.qty,0)) FROM public.inventory_purchase_request_lines l
 LEFT JOIN quoted q ON q.request_line_id=l.id WHERE l.request_id=p_request_id AND l.active
$$;
CREATE FUNCTION public.procurement_brand_hash(p_request_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 WITH coverage AS MATERIALIZED (SELECT public.procurement_commercial_coverage(p_request_id) complete), quoted AS (SELECT ql.request_line_id,jsonb_agg(jsonb_build_object('supplier',q.supplier_id,'qty',ql.quantity_base,
 'price_base',round(ql.unit_price/ql.conversion_snapshot,8),'vat',ql.tax_rate,'delivery',q.delivery_date) ORDER BY q.supplier_id,ql.id) terms
 FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id
 WHERE q.request_id=p_request_id AND q.selected AND NOT q.archived GROUP BY ql.request_line_id),
 terms AS (SELECT l.id,l.product_id,l.quantity_base,l.specification_snapshot,l.receipt_classification,
 CASE WHEN coverage.complete THEN q.terms ELSE jsonb_build_array(jsonb_build_object(
 'supplier',l.preferred_supplier_id,'qty',l.quantity_base,'price_base',round(l.estimated_unit_price/NULLIF(l.estimated_conversion,0),8),
 'vat',l.estimated_tax_rate,'delivery',r.requested_delivery_date)) END commercial
 FROM public.inventory_purchase_request_lines l JOIN public.inventory_purchase_requests r ON r.id=l.request_id
 LEFT JOIN quoted q ON q.request_line_id=l.id CROSS JOIN coverage WHERE l.request_id=p_request_id AND l.active)
 SELECT encode(extensions.digest(convert_to(jsonb_build_object('date',r.requested_delivery_date,'category',r.purchase_category,'channel',r.purchase_channel,
 'lines',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM terms t))::text,'UTF8'),'sha256'),'hex')
 FROM public.inventory_purchase_requests r WHERE r.id=p_request_id
$$;
REVOKE ALL ON FUNCTION public.procurement_commercial_coverage(uuid),public.procurement_brand_hash(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.procurement_request_hash(p_request_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 WITH selected AS MATERIALIZED(SELECT * FROM public.procurement_quotes WHERE request_id=p_request_id AND selected),
 quote_lines AS(SELECT l.quote_id,jsonb_agg(to_jsonb(l) ORDER BY l.id) rows FROM public.procurement_quote_lines l JOIN selected q ON q.id=l.quote_id GROUP BY l.quote_id),
 quotes AS(SELECT jsonb_agg(to_jsonb(q)||jsonb_build_object('lines',l.rows) ORDER BY q.id) rows FROM selected q LEFT JOIN quote_lines l ON l.quote_id=q.id),
 lines AS(SELECT jsonb_agg(CASE WHEN r.approval_policy_version=1 THEN to_jsonb(l)-ARRAY['product_name_snapshot','specification_snapshot','receipt_classification','estimated_unit_price','estimated_tax_rate','estimated_conversion','estimated_order_unit','estimated_supplier_item_id'] ELSE to_jsonb(l) END ORDER BY l.id) rows
 FROM public.inventory_purchase_request_lines l JOIN public.inventory_purchase_requests r ON r.id=l.request_id WHERE l.request_id=p_request_id AND l.active)
 SELECT encode(extensions.digest(convert_to(jsonb_build_object('request',jsonb_build_object('id',r.id,'store',r.restaurant_id,'date',r.requested_delivery_date,'reason',r.reason),
 'lines',l.rows,'quotes',q.rows)::text,'UTF8'),'sha256'),'hex') FROM public.inventory_purchase_requests r CROSS JOIN lines l CROSS JOIN quotes q WHERE r.id=p_request_id
$$;
REVOKE ALL ON FUNCTION public.procurement_request_hash(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.procurement_core_command(
 p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,
 p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; actor_key text; input_hash text; prior public.procurement_command_results%rowtype;
 policy public.procurement_store_policies%rowtype; req public.inventory_purchase_requests%rowtype;
 old_state jsonb; result jsonb; item jsonb; product public.inventory_products%rowtype;
 line public.inventory_purchase_request_lines%rowtype; quote public.procurement_quotes%rowtype;
 qline public.procurement_quote_lines%rowtype; supplier_item public.inventory_supplier_items%rowtype;
 po public.inventory_purchase_orders%rowtype; po_line public.inventory_purchase_order_lines%rowtype;
 v_quantity numeric; conversion numeric; total numeric; new_id uuid; command_reason text; senior_required boolean;
 saved_write text:=current_setting('app.procurement_write',true);
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 actor_key:=(actor->>'system')||':'||(actor->>'subject_id');
 IF NULLIF(btrim(p_idempotency_key),'') IS NULL OR length(p_idempotency_key)>160 THEN
   RAISE EXCEPTION 'PROCUREMENT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
 IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'PROCUREMENT_PAYLOAD_INVALID'; END IF;
 input_hash:=encode(extensions.digest(convert_to(jsonb_build_object('action',p_action,'record',p_record_id,
   'version',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_idempotency_key,0));
 SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_idempotency_key;
 IF FOUND THEN
   IF prior.actor_key<>actor_key OR prior.payload_hash<>input_hash THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH'; END IF;
   RETURN prior.result;
 END IF;
 command_reason:=NULLIF(btrim(p_payload->>'reason'),'');
 IF p_action='configure' THEN PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,7)); END IF;
 IF p_action='configure' THEN SELECT * INTO policy FROM public.procurement_store_policies WHERE restaurant_id=p_store_id FOR UPDATE;
 ELSE SELECT * INTO policy FROM public.procurement_store_policies WHERE restaurant_id=p_store_id FOR SHARE; END IF;
 IF p_action='configure' THEN
   IF COALESCE((actor->>'can_manage')::boolean,false)=false THEN RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN'; END IF;
   IF policy.restaurant_id IS NOT NULL AND policy.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
   old_state:=to_jsonb(policy);
   INSERT INTO public.procurement_store_policies(restaurant_id,enabled,high_value_amount,max_price_increase_percent,stock_freshness_hours,quantity_review_multiplier,three_stage_required,new_requests_enabled)
   VALUES(p_store_id,COALESCE((p_payload->>'enabled')::boolean,false),(p_payload->>'high_value_amount')::numeric,
   (p_payload->>'max_price_increase_percent')::numeric,COALESCE((p_payload->>'stock_freshness_hours')::integer,24),(p_payload->>'quantity_review_multiplier')::numeric,COALESCE((p_payload->>'three_stage_required')::boolean,policy.three_stage_required,false),COALESCE((p_payload->>'new_requests_enabled')::boolean,policy.new_requests_enabled,true))
   ON CONFLICT(restaurant_id) DO UPDATE SET enabled=EXCLUDED.enabled,high_value_amount=EXCLUDED.high_value_amount,
     max_price_increase_percent=EXCLUDED.max_price_increase_percent,stock_freshness_hours=EXCLUDED.stock_freshness_hours,
     quantity_review_multiplier=EXCLUDED.quantity_review_multiplier,three_stage_required=EXCLUDED.three_stage_required,new_requests_enabled=EXCLUDED.new_requests_enabled,
     row_version=procurement_store_policies.row_version+1,updated_at=now() RETURNING * INTO policy;
   result:=to_jsonb(policy)||jsonb_build_object('id',p_store_id);
 ELSE
   IF NOT COALESCE(policy.enabled,false) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_ENABLED'; END IF;
   IF p_action='save_product' THEN
     IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
     IF NULLIF(btrim(p_payload->>'name'),'') IS NULL OR NULLIF(btrim(p_payload->>'product_code'),'') IS NULL OR
       NULLIF(btrim(p_payload->>'stock_unit'),'') IS NULL OR NULLIF(btrim(p_payload->>'base_unit'),'') IS NULL OR
       COALESCE((p_payload->>'base_unit_factor')::numeric,0)<=0 OR (p_payload->>'base_unit_factor')::numeric::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_FIELDS_REQUIRED'; END IF;
     IF NULLIF(p_payload->>'inventory_item_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.inventory_items WHERE id=(p_payload->>'inventory_item_id')::uuid AND restaurant_id=p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_STOCK_MAPPING_INVALID'; END IF;
     IF p_payload->>'receipt_classification'='stock' AND NULLIF(p_payload->>'inventory_item_id','') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_STOCK_MAPPING_INVALID'; END IF;
     IF p_record_id IS NOT NULL THEN
       SELECT * INTO product FROM public.inventory_products WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
       RAISE EXCEPTION 'PROCUREMENT_PRODUCT_CREATE_ONLY';
     END IF;
     INSERT INTO public.inventory_products(restaurant_id,brand_id,product_code,name,specification,stock_unit,base_unit,base_unit_factor,receipt_classification,inventory_item_id)
     SELECT p_store_id,r.brand_id,p_payload->>'product_code',p_payload->>'name',COALESCE(p_payload->>'specification',''),p_payload->>'stock_unit',p_payload->>'base_unit',
       (p_payload->>'base_unit_factor')::numeric,p_payload->>'receipt_classification',NULLIF(p_payload->>'inventory_item_id','')::uuid FROM public.restaurants r WHERE r.id=p_store_id RETURNING * INTO product;
     IF NOT EXISTS(SELECT 1 FROM public.inventory_suppliers s WHERE s.id=(p_payload->>'supplier_id')::uuid AND s.status='active' AND(s.brand_id IS NULL OR s.brand_id=product.brand_id)) THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_INVALID'; END IF;
     INSERT INTO public.inventory_supplier_items(supplier_id,product_id,order_unit,order_unit_quantity_base,min_order_quantity,unit_price,tax_rate,is_preferred)
     VALUES((p_payload->>'supplier_id')::uuid,product.id,p_payload->>'stock_unit',(p_payload->>'base_unit_factor')::numeric,1,(p_payload->>'unit_price')::numeric,(p_payload->>'tax_rate')::numeric,true);
     result:=to_jsonb(product);
   ELSIF p_action='record_channel_payment' THEN
     IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
     SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id AND workflow_version=2 FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
     IF po.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
     IF po.commercial_terms->>'purchase_channel' IS DISTINCT FROM 'shopee' OR (po.status IN ('cancelled','rejected') AND p_payload->>'kind'='advance') THEN RAISE EXCEPTION 'PROCUREMENT_CHANNEL_INVALID'; END IF;
     IF NULLIF(btrim(p_payload->>'external_order_no'),'') IS NULL OR NULLIF(btrim(p_payload->>'payment_reference'),'') IS NULL OR NULLIF(btrim(p_payload->>'evidence_reference'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_CHANNEL_EVIDENCE_REQUIRED'; END IF;
     IF po.commercial_terms->>'external_order_no' IS NOT NULL AND po.commercial_terms->>'external_order_no'<>p_payload->>'external_order_no' THEN RAISE EXCEPTION 'PROCUREMENT_CHANNEL_ORDER_CHANGED'; END IF;
     v_quantity:=(p_payload->>'amount')::numeric;
     IF v_quantity IS NULL OR v_quantity<=0 OR v_quantity<>round(v_quantity,2) OR v_quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'PROCUREMENT_PAYMENT_AMOUNT_INVALID'; END IF;
     SELECT COALESCE(sum(CASE WHEN kind='advance' THEN amount WHEN kind='refund' THEN -amount ELSE 0 END),0) INTO total FROM public.procurement_channel_payments WHERE purchase_order_id=po.id;
     IF p_payload->>'kind'='advance' AND total+v_quantity>po.total_amount THEN RAISE EXCEPTION 'PROCUREMENT_PREPAYMENT_EXCEEDS_ORDER'; END IF;
     IF p_payload->>'kind'='refund' THEN
       SELECT COALESCE(sum(CASE WHEN kind='advance' THEN amount WHEN kind='refund' THEN -amount ELSE 0 END),0) INTO total FROM public.procurement_channel_payments WHERE purchase_order_id=po.id AND paid_by=p_payload->>'paid_by';
       IF v_quantity>total THEN RAISE EXCEPTION 'PROCUREMENT_REFUND_EXCEEDS_PREPAYMENT'; END IF;
     END IF;
     IF p_payload->>'kind'='reimbursement' THEN
       IF p_payload->>'paid_by' IS DISTINCT FROM 'employee' THEN RAISE EXCEPTION 'PROCUREMENT_REIMBURSEMENT_OWNER_INVALID'; END IF;
       SELECT COALESCE(sum(CASE WHEN kind='advance' AND paid_by='employee' THEN amount WHEN kind IN ('refund','reimbursement') AND paid_by='employee' THEN -amount ELSE 0 END),0) INTO total FROM public.procurement_channel_payments WHERE purchase_order_id=po.id;
       IF v_quantity>total THEN RAISE EXCEPTION 'PROCUREMENT_REIMBURSEMENT_EXCEEDS_ADVANCE'; END IF;
     END IF;
     old_state:=to_jsonb(po);
     INSERT INTO public.procurement_channel_payments(restaurant_id,purchase_order_id,external_order_no,kind,paid_by,amount,payment_reference,evidence_reference,actor)
       VALUES(p_store_id,po.id,p_payload->>'external_order_no',p_payload->>'kind',p_payload->>'paid_by',v_quantity,p_payload->>'payment_reference',p_payload->>'evidence_reference',actor);
     PERFORM set_config('app.procurement_write','true',true);
     UPDATE public.inventory_purchase_orders SET commercial_terms=commercial_terms||jsonb_build_object('external_order_no',p_payload->>'external_order_no'),row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING * INTO po;
     result:=to_jsonb(po);
   ELSIF p_action IN ('create_request','save_request') THEN
     IF p_action='create_request' AND NOT policy.new_requests_enabled THEN RAISE EXCEPTION 'PROCUREMENT_NEW_REQUESTS_PAUSED'; END IF;
     IF NOT COALESCE((actor->>'can_create')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_CREATE_FORBIDDEN'; END IF;
     IF command_reason IS NULL OR NULLIF(p_payload->>'requested_delivery_date','') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REQUEST_FIELDS_REQUIRED'; END IF;
     IF p_action='save_request' THEN
       SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
       IF req.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
       IF req.status NOT IN ('draft','returned') OR req.created_actor->>'subject_id'<>actor->>'subject_id'
         OR req.created_actor->>'system'<>actor->>'system' THEN RAISE EXCEPTION 'PROCUREMENT_REQUEST_NOT_EDITABLE'; END IF;
       old_state:=to_jsonb(req);
       -- Returned drafts preserve the old complete line content in the event before replacement.
       old_state:=old_state||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(l)) FROM public.inventory_purchase_request_lines l WHERE request_id=req.id AND active));
       UPDATE public.procurement_quotes SET selected=false,archived=true WHERE request_id=req.id;
       UPDATE public.inventory_purchase_request_lines SET active=false WHERE request_id=req.id;
       UPDATE public.inventory_purchase_requests SET reason=command_reason,requested_delivery_date=(p_payload->>'requested_delivery_date')::date,
         memo=p_payload->>'memo',status='draft',row_version=row_version+1,updated_at=now(),store_approved_actor=NULL,
         office_approved_actor=NULL,senior_approved_actor=NULL,approval_hash=NULL,brand_approved_actor=NULL,brand_approval_hash=NULL,brand_approved_at=NULL,store_approved_at=NULL,
         purchase_category=COALESCE(p_payload->>'purchase_category','raw_material'),purchase_channel=COALESCE(p_payload->>'purchase_channel','ordinary') WHERE id=req.id RETURNING * INTO req;
     ELSE
       INSERT INTO public.inventory_purchase_requests(restaurant_id,source,requested_delivery_date,reason,memo,created_actor,approval_policy_version,purchase_category,purchase_channel)
       VALUES(p_store_id,actor->>'system',(p_payload->>'requested_delivery_date')::date,command_reason,p_payload->>'memo',actor,CASE WHEN policy.three_stage_required THEN 2 ELSE 1 END,
         COALESCE(p_payload->>'purchase_category','raw_material'),COALESCE(p_payload->>'purchase_channel','ordinary')) RETURNING * INTO req;
     END IF;
     IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines') NOT BETWEEN 1 AND 200 THEN
       RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
     -- Validate and insert the entire line set together; no product lookup per row.
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x
       LEFT JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid AND p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
       WHERE p.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x WHERE
       (x->>'quantity')::numeric IS NULL OR (x->>'quantity')::numeric<=0 OR
       (x->>'quantity')::numeric<>round((x->>'quantity')::numeric,3) OR (x->>'quantity')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN
       RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
       WHERE x->>'unit' IS NULL OR x->>'unit' NOT IN (p.base_unit,p.stock_unit)) THEN RAISE EXCEPTION 'PROCUREMENT_UNIT_INVALID'; END IF;
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
       WHERE NULLIF(x->>'preferred_supplier_id','') IS NOT NULL AND NOT EXISTS(
         SELECT 1 FROM public.inventory_supplier_items si JOIN public.inventory_suppliers s ON s.id=si.supplier_id
         WHERE si.product_id=p.id AND si.supplier_id=(x->>'preferred_supplier_id')::uuid AND si.is_active AND s.status='active'
         AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id)))) THEN
       RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_INVALID'; END IF;
     INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot,
       current_stock_snapshot,stock_updated_at,preferred_supplier_id,memo,product_name_snapshot,specification_snapshot,receipt_classification,
       estimated_unit_price,estimated_tax_rate,estimated_conversion,estimated_order_unit,estimated_supplier_item_id)
     WITH estimates AS (SELECT DISTINCT ON (si.product_id,si.supplier_id) si.* FROM public.inventory_supplier_items si
       JOIN public.inventory_products p ON p.id=si.product_id AND p.restaurant_id=p_store_id
       WHERE si.is_active ORDER BY si.product_id,si.supplier_id,si.is_preferred DESC,si.id)
     SELECT req.id,p.id,(x->>'quantity')::numeric,x->>'unit',
       (x->>'quantity')::numeric*CASE WHEN x->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,
       CASE WHEN x->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,it.current_stock,it.updated_at,
       NULLIF(x->>'preferred_supplier_id','')::uuid,x->>'memo',p.name,p.specification,p.receipt_classification,
       e.unit_price,e.tax_rate,e.order_unit_quantity_base,e.order_unit,e.id
     FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
     LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
     LEFT JOIN estimates e ON e.product_id=p.id AND e.supplier_id=NULLIF(x->>'preferred_supplier_id','')::uuid;
     result:=to_jsonb(req);
   ELSIF p_action IN ('send_po','confirm_po') THEN
     IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
     SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id AND workflow_version=2 FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
     IF po.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
     IF (p_action='send_po' AND po.procurement_status<>'issued') OR (p_action='confirm_po' AND po.procurement_status<>'sent') THEN
       RAISE EXCEPTION 'PROCUREMENT_INVALID_TRANSITION'; END IF;
     IF NULLIF(btrim(p_payload->>'evidence_reference'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_EVIDENCE_REQUIRED'; END IF;
     IF p_action='confirm_po' AND p_payload->>'terms_hash' IS DISTINCT FROM po.approval_snapshot_hash THEN
       RAISE EXCEPTION 'PROCUREMENT_CONFIRMATION_TERMS_CHANGED'; END IF;
     IF p_action='send_po' AND (po.commercial_terms->>'approval_policy_version')::integer=2 AND NOT EXISTS(
       SELECT 1 FROM public.procurement_document_exports d WHERE d.record_id=po.id AND d.kind='po' AND d.audience='supplier'
         AND d.source_hash=po.approval_snapshot_hash AND d.status='ready') THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_DOCUMENT_REQUIRED'; END IF;
     old_state:=to_jsonb(po);
     PERFORM set_config('app.procurement_write','true',true);
     UPDATE public.inventory_purchase_orders SET procurement_status=CASE WHEN p_action='send_po' THEN 'sent' ELSE 'confirmed' END,
       commercial_terms=commercial_terms||jsonb_build_object(p_action,jsonb_build_object('actor',actor,'at',now(),'evidence_reference',p_payload->>'evidence_reference')),
       ordered_at=COALESCE(ordered_at,now()),row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING * INTO po;
     result:=to_jsonb(po);
   ELSE
     SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
     IF req.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
     old_state:=to_jsonb(req);
     CASE p_action
     WHEN 'submit_request' THEN
       IF NOT COALESCE((actor->>'can_create')::boolean,false) OR req.created_actor->>'subject_id'<>actor->>'subject_id'
         OR req.created_actor->>'system'<>actor->>'system' OR req.status NOT IN ('draft','returned') THEN RAISE EXCEPTION 'PROCUREMENT_INVALID_TRANSITION'; END IF;
       IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines WHERE request_id=req.id AND active) THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
       UPDATE public.inventory_purchase_requests SET status='submitted',submitted_at=COALESCE(submitted_at,now()) WHERE id=req.id;
     WHEN 'store_approve' THEN
       IF NOT COALESCE((actor->>'can_store_approve')::boolean,false) OR req.status<>'submitted' THEN RAISE EXCEPTION 'PROCUREMENT_STORE_APPROVAL_FORBIDDEN'; END IF;
       UPDATE public.inventory_purchase_requests SET status=CASE WHEN req.approval_policy_version=2 THEN 'brand_review' ELSE 'office_review' END,
         store_approved_actor=actor,store_approved_at=now() WHERE id=req.id;
     WHEN 'adjust_request' THEN
       IF NOT COALESCE((actor->>'can_store_approve')::boolean,false) OR req.status<>'submitted' THEN RAISE EXCEPTION 'PROCUREMENT_STORE_APPROVAL_FORBIDDEN'; END IF;
       IF command_reason IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_REQUIRED'; END IF;
       IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines')=0 THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x
         LEFT JOIN public.inventory_purchase_request_lines l ON l.id=(x->>'request_line_id')::uuid AND l.request_id=req.id AND l.active
         WHERE l.id IS NULL OR (x->>'quantity')::numeric IS NULL OR (x->>'quantity')::numeric<=0 OR
           (x->>'quantity')::numeric<>round((x->>'quantity')::numeric,3) OR (x->>'quantity')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x GROUP BY x->>'request_line_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'PROCUREMENT_LINE_INVALID'; END IF;
       old_state:=old_state||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(l)) FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active));
       UPDATE public.inventory_purchase_request_lines l SET requested_quantity=(x->>'quantity')::numeric,
         quantity_base=(x->>'quantity')::numeric*l.conversion_snapshot
       FROM jsonb_array_elements(p_payload->'lines') x WHERE l.id=(x->>'request_line_id')::uuid;
       UPDATE public.inventory_purchase_requests SET brand_approved_actor=NULL,brand_approval_hash=NULL WHERE id=req.id;
     WHEN 'brand_approve' THEN
       IF req.approval_policy_version<>2 OR NOT COALESCE((actor->>'can_brand_approve')::boolean,false) OR req.status<>'brand_review' THEN RAISE EXCEPTION 'PROCUREMENT_BRAND_APPROVAL_FORBIDDEN'; END IF;
       IF req.store_approved_actor->>'subject_id'=actor->>'subject_id' AND req.store_approved_actor->>'system'=actor->>'system' THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
       IF NOT public.procurement_commercial_coverage(req.id) AND EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines WHERE request_id=req.id AND active AND (estimated_unit_price IS NULL OR estimated_unit_price<=0)) THEN RAISE EXCEPTION 'PROCUREMENT_ESTIMATE_REQUIRED'; END IF;
       UPDATE public.inventory_purchase_requests SET status='office_review',brand_approved_actor=actor,brand_approved_at=now(),
         brand_approval_hash=public.procurement_brand_hash(req.id) WHERE id=req.id;
     WHEN 'cancel_request' THEN
       IF command_reason IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_REQUIRED'; END IF;
       IF req.status IN ('allocated','cancelled') OR EXISTS(SELECT 1 FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE l.request_id=req.id) THEN RAISE EXCEPTION 'PROCUREMENT_ALLOCATED_TERMS_IMMUTABLE'; END IF;
       IF NOT ((req.created_actor->>'subject_id'=actor->>'subject_id' AND req.created_actor->>'system'=actor->>'system' AND req.status IN ('draft','returned')) OR COALESCE((actor->>'can_office_approve')::boolean,false)) THEN RAISE EXCEPTION 'PROCUREMENT_CANCEL_FORBIDDEN'; END IF;
       UPDATE public.inventory_purchase_requests SET status='cancelled',approval_hash=NULL WHERE id=req.id;
     WHEN 'return_request' THEN
       IF command_reason IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_REQUIRED'; END IF;
       IF NOT ((req.status='submitted' AND COALESCE((actor->>'can_store_approve')::boolean,false))
         OR (req.status='brand_review' AND COALESCE((actor->>'can_brand_approve')::boolean,false))
         OR (req.status IN ('office_review','senior_review') AND COALESCE((actor->>'can_office_approve')::boolean,false))) THEN
         RAISE EXCEPTION 'PROCUREMENT_RETURN_FORBIDDEN'; END IF;
       UPDATE public.inventory_purchase_requests SET status='returned',approval_hash=NULL,store_approved_actor=NULL,brand_approved_actor=NULL,brand_approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
     WHEN 'save_quote' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status NOT IN ('brand_review','office_review','senior_review','approved') THEN
         RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
       IF EXISTS(SELECT 1 FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE l.request_id=req.id) THEN
         RAISE EXCEPTION 'PROCUREMENT_ALLOCATED_TERMS_IMMUTABLE'; END IF;
       IF NOT EXISTS(SELECT 1 FROM public.inventory_suppliers s WHERE s.id=(p_payload->>'supplier_id')::uuid AND s.status='active'
         AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))) THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_INVALID'; END IF;
       IF NULLIF(btrim(p_payload->>'payment_terms'),'') IS NULL OR NULLIF(btrim(p_payload->>'evidence_reference'),'') IS NULL THEN
         RAISE EXCEPTION 'PROCUREMENT_QUOTE_FIELDS_REQUIRED'; END IF;
       INSERT INTO public.procurement_quotes(request_id,supplier_id,valid_until,delivery_date,payment_terms,evidence_reference)
       VALUES(req.id,(p_payload->>'supplier_id')::uuid,(p_payload->>'valid_until')::date,(p_payload->>'delivery_date')::date,
         p_payload->>'payment_terms',p_payload->>'evidence_reference') RETURNING * INTO quote;
       IF quote.valid_until<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines')=0 THEN
         RAISE EXCEPTION 'PROCUREMENT_QUOTE_INVALID'; END IF;
       IF jsonb_array_length(p_payload->'lines')>200 THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x LEFT JOIN public.inventory_purchase_request_lines l
         ON l.id=(x->>'request_line_id')::uuid AND l.request_id=req.id AND l.active WHERE l.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_LINE_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_purchase_request_lines l ON l.id=(x->>'request_line_id')::uuid
         LEFT JOIN public.inventory_supplier_items i ON i.id=(x->>'supplier_item_id')::uuid AND i.product_id=l.product_id AND i.supplier_id=quote.supplier_id AND i.is_active WHERE i.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_ITEM_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_purchase_request_lines l ON l.id=(x->>'request_line_id')::uuid
         WHERE (x->>'quantity_base')::numeric IS NULL OR (x->>'quantity_base')::numeric<=0 OR (x->>'quantity_base')::numeric>l.quantity_base OR (x->>'quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_supplier_items i ON i.id=(x->>'supplier_item_id')::uuid
         WHERE (NOT COALESCE(i.allows_fractional_quantity,false) AND (x->>'quantity_base')::numeric/i.order_unit_quantity_base<>trunc((x->>'quantity_base')::numeric/i.order_unit_quantity_base))) THEN RAISE EXCEPTION 'PROCUREMENT_ORDER_PRECISION_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_supplier_items i ON i.id=(x->>'supplier_item_id')::uuid
         WHERE round((x->>'quantity_base')::numeric/i.order_unit_quantity_base,3)*i.order_unit_quantity_base<>(x->>'quantity_base')::numeric) THEN RAISE EXCEPTION 'PROCUREMENT_ORDER_PRECISION_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_supplier_items i ON i.id=(x->>'supplier_item_id')::uuid
         WHERE (x->>'quantity_base')::numeric/i.order_unit_quantity_base<i.min_order_quantity) THEN RAISE EXCEPTION 'PROCUREMENT_MOQ_REQUIRED'; END IF;
       INSERT INTO public.procurement_quote_lines(quote_id,request_line_id,supplier_item_id,quantity_base,order_unit,conversion_snapshot,unit_price,tax_rate,reference_unit_price)
       SELECT quote.id,(x->>'request_line_id')::uuid,i.id,(x->>'quantity_base')::numeric,i.order_unit,i.order_unit_quantity_base,(x->>'unit_price')::numeric,(x->>'tax_rate')::numeric,i.unit_price
       FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_supplier_items i ON i.id=(x->>'supplier_item_id')::uuid;
       UPDATE public.inventory_purchase_requests SET status=CASE WHEN req.approval_policy_version=2 AND req.brand_approved_actor IS NULL THEN 'brand_review' ELSE 'office_review' END,approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
     WHEN 'select_quote' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status NOT IN ('brand_review','office_review','senior_review','approved') OR command_reason IS NULL THEN
         RAISE EXCEPTION 'PROCUREMENT_SELECTION_FORBIDDEN'; END IF;
       IF EXISTS(SELECT 1 FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE l.request_id=req.id) THEN
         RAISE EXCEPTION 'PROCUREMENT_ALLOCATED_TERMS_IMMUTABLE'; END IF;
       UPDATE public.procurement_quotes SET selected=COALESCE((p_payload->>'selected')::boolean,true),selection_reason=command_reason,row_version=row_version+1
         WHERE id=(p_payload->>'quote_id')::uuid AND request_id=req.id AND NOT archived AND valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date RETURNING * INTO quote;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_QUOTE_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active AND l.quantity_base<(
         SELECT sum(ql.quantity_base) FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id
         WHERE ql.request_line_id=l.id AND q.selected)) THEN RAISE EXCEPTION 'PROCUREMENT_OVER_ALLOCATION'; END IF;
       UPDATE public.inventory_purchase_requests SET status=CASE WHEN req.approval_policy_version=2 AND req.brand_approved_actor IS NULL THEN 'brand_review' ELSE 'office_review' END,approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
       IF req.approval_policy_version=2 AND public.procurement_commercial_coverage(req.id) AND req.brand_approval_hash IS DISTINCT FROM public.procurement_brand_hash(req.id) THEN
         UPDATE public.inventory_purchase_requests SET status='brand_review',brand_approved_actor=NULL,brand_approval_hash=NULL,brand_approved_at=NULL WHERE id=req.id;
       END IF;
     WHEN 'office_approve' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status<>'office_review' THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
       IF req.approval_policy_version=2 THEN
         IF req.brand_approved_actor IS NULL OR req.brand_approval_hash IS DISTINCT FROM public.procurement_brand_hash(req.id) THEN RAISE EXCEPTION 'PROCUREMENT_BRAND_APPROVAL_REQUIRED'; END IF;
         IF req.brand_approved_actor->>'subject_id'=actor->>'subject_id' AND req.brand_approved_actor->>'system'=actor->>'system' THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
       END IF;
       IF NOT EXISTS(SELECT 1 FROM public.procurement_quotes WHERE request_id=req.id AND selected) OR EXISTS(
         SELECT 1 FROM public.procurement_quotes WHERE request_id=req.id AND selected AND valid_until<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) THEN RAISE EXCEPTION 'PROCUREMENT_QUOTE_REQUIRED'; END IF;
       IF EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active AND l.quantity_base<>COALESCE((
         SELECT sum(ql.quantity_base) FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id WHERE ql.request_line_id=l.id AND q.selected),0)) THEN
         RAISE EXCEPTION 'PROCUREMENT_QUOTE_COVERAGE_REQUIRED'; END IF;
       SELECT sum(round(ql.quantity_base/ql.conversion_snapshot*ql.unit_price,2)+round(ql.quantity_base/ql.conversion_snapshot*ql.unit_price*ql.tax_rate/100,2)),
         bool_or(ql.reference_unit_price<=0 OR policy.max_price_increase_percent IS NULL OR ql.unit_price>ql.reference_unit_price*(1+policy.max_price_increase_percent/100))
       INTO total,senior_required FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id WHERE q.request_id=req.id AND q.selected;
       IF EXISTS(SELECT 1 FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id
         WHERE q.request_id=req.id AND q.selected AND (ql.reference_unit_price<=0 OR NOT EXISTS(
           SELECT 1 FROM public.inventory_receipt_lines historical_line
           JOIN public.inventory_receipts historical_receipt ON historical_receipt.id=historical_line.receipt_id
           JOIN public.inventory_purchase_request_lines requested_line ON requested_line.id=ql.request_line_id
           WHERE historical_line.product_id=requested_line.product_id AND historical_receipt.restaurant_id=p_store_id
             AND historical_receipt.status='confirmed' AND historical_line.accepted_quantity_base>0) OR
           (policy.max_price_increase_percent IS NOT NULL AND ql.unit_price>ql.reference_unit_price*(1+policy.max_price_increase_percent/100)))
         AND (SELECT count(DISTINCT qq.supplier_id) FROM public.procurement_quotes qq JOIN public.procurement_quote_lines ll ON ll.quote_id=qq.id
           WHERE qq.request_id=req.id AND NOT qq.archived AND qq.valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AND ll.request_line_id=ql.request_line_id)<2) THEN
         RAISE EXCEPTION 'PROCUREMENT_COMPARATIVE_QUOTES_REQUIRED'; END IF;
       senior_required:=COALESCE(senior_required,true) OR policy.quantity_review_multiplier IS NULL OR EXISTS(
         SELECT 1 FROM public.inventory_purchase_request_lines l LEFT JOIN LATERAL (
           SELECT avg(rl.accepted_quantity_base) qty FROM public.inventory_receipt_lines rl JOIN public.inventory_receipts rr ON rr.id=rl.receipt_id
           WHERE rl.product_id=l.product_id AND rr.restaurant_id=p_store_id AND rr.status='confirmed' AND rr.received_at>=now()-interval '90 days' AND rl.accepted_quantity_base>0
         ) h ON true WHERE l.request_id=req.id AND l.active AND (h.qty IS NULL OR l.quantity_base>h.qty*policy.quantity_review_multiplier));
       senior_required:=COALESCE(senior_required,true) OR policy.high_value_amount IS NULL OR total>=policy.high_value_amount;
       senior_required:=senior_required OR EXISTS(SELECT 1 FROM public.procurement_quote_lines ql
         JOIN public.procurement_quotes q ON q.id=ql.quote_id JOIN public.inventory_supplier_items si ON si.id=ql.supplier_item_id
         WHERE q.request_id=req.id AND q.selected AND NOT si.is_preferred);
       UPDATE public.inventory_purchase_requests SET status=CASE WHEN senior_required THEN 'senior_review' ELSE 'approved' END,
         approved_amount=total,office_approved_actor=actor,office_approved_at=now(),approval_hash=public.procurement_request_hash(req.id) WHERE id=req.id;
     WHEN 'senior_approve' THEN
       IF NOT COALESCE((actor->>'can_senior_approve')::boolean,false) OR req.status<>'senior_review' THEN RAISE EXCEPTION 'PROCUREMENT_SENIOR_FORBIDDEN'; END IF;
       IF req.office_approved_actor->>'subject_id'=actor->>'subject_id' AND req.office_approved_actor->>'system'=actor->>'system' THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
       IF req.approval_hash IS DISTINCT FROM public.procurement_request_hash(req.id) THEN RAISE EXCEPTION 'PROCUREMENT_APPROVAL_STALE'; END IF;
       UPDATE public.inventory_purchase_requests SET status='approved',senior_approved_actor=actor WHERE id=req.id;
     WHEN 'issue_po' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status<>'approved' THEN RAISE EXCEPTION 'PROCUREMENT_ISSUE_FORBIDDEN'; END IF;
       IF req.approval_hash IS DISTINCT FROM public.procurement_request_hash(req.id) THEN RAISE EXCEPTION 'PROCUREMENT_APPROVAL_STALE'; END IF;
       SELECT * INTO quote FROM public.procurement_quotes WHERE id=(p_payload->>'quote_id')::uuid AND request_id=req.id AND selected AND valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_QUOTE_INVALID'; END IF;
       IF NULLIF(btrim(p_payload->>'delivery_address'),'') IS NULL OR NULLIF(btrim(p_payload->>'contact_name'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_DELIVERY_FIELDS_REQUIRED'; END IF;
       PERFORM set_config('app.procurement_write','true',true);
       INSERT INTO public.inventory_purchase_orders(purchase_order_no,restaurant_id,brand_id,supplier_id,status,order_type,source,requested_delivery_date,
         workflow_version,procurement_status,commercial_terms,approval_snapshot_hash)
       SELECT 'PO-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),p_store_id,r.brand_id,quote.supplier_id,
         'draft','manual','office',quote.delivery_date,2,'issued',jsonb_build_object('request_id',req.id,'quote_id',quote.id,
           'approval_policy_version',req.approval_policy_version,'purchase_category',req.purchase_category,'purchase_channel',req.purchase_channel,'pr_no',req.request_no,'pr_created_at',req.created_at,'pr_submitted_at',req.submitted_at,
           'store_approval',jsonb_build_object('actor',req.store_approved_actor,'at',req.store_approved_at),
           'brand_approval',jsonb_build_object('actor',req.brand_approved_actor,'at',req.brand_approved_at),
           'purchase_approval',jsonb_build_object('actor',req.office_approved_actor,'at',req.office_approved_at),
           'payment_terms',quote.payment_terms,'delivery_address',p_payload->>'delivery_address','contact_name',p_payload->>'contact_name','issued_by',actor,'issued_at',now()),req.approval_hash
       FROM public.restaurants r WHERE r.id=p_store_id RETURNING * INTO po;
       -- Lock in a stable order, validate allocation totals once, then issue all lines together.
       PERFORM 1 FROM public.inventory_purchase_request_lines l JOIN public.procurement_quote_lines ql ON ql.request_line_id=l.id WHERE ql.quote_id=quote.id ORDER BY l.id FOR UPDATE OF l;
       IF EXISTS(WITH allocated AS(SELECT a.request_line_id,sum(a.quantity_base) qty FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE l.request_id=req.id GROUP BY a.request_line_id)
         SELECT 1 FROM public.procurement_quote_lines ql JOIN public.inventory_purchase_request_lines l ON l.id=ql.request_line_id LEFT JOIN allocated a ON a.request_line_id=l.id
         WHERE ql.quote_id=quote.id AND (l.quantity_base<ql.quantity_base+COALESCE(a.qty,0) OR EXISTS(SELECT 1 FROM public.procurement_allocations existing WHERE existing.quote_line_id=ql.id))) THEN RAISE EXCEPTION 'PROCUREMENT_OVER_ALLOCATION'; END IF;
       INSERT INTO public.inventory_purchase_order_lines(purchase_order_id,product_id,supplier_item_id,ordered_quantity_base,ordered_quantity_unit,order_unit,unit_price,supply_amount,tax_amount,recommendation_snapshot,memo)
       SELECT po.id,l.product_id,ql.supplier_item_id,ql.quantity_base,ql.quantity_base/ql.conversion_snapshot,ql.order_unit,ql.unit_price,
         round(ql.quantity_base/ql.conversion_snapshot*ql.unit_price,2),round(ql.quantity_base/ql.conversion_snapshot*ql.unit_price*ql.tax_rate/100,2),
         jsonb_build_object('tax_rate',ql.tax_rate,'order_unit_quantity_base',ql.conversion_snapshot,'request_line_id',l.id,'quote_line_id',ql.id,
           'product_name',l.product_name_snapshot,'specification',l.specification_snapshot,'receipt_classification',l.receipt_classification),l.memo
       FROM public.procurement_quote_lines ql JOIN public.inventory_purchase_request_lines l ON l.id=ql.request_line_id WHERE ql.quote_id=quote.id;
       INSERT INTO public.procurement_allocations(request_line_id,quote_line_id,purchase_order_line_id,quantity_base)
       SELECT (l.recommendation_snapshot->>'request_line_id')::uuid,(l.recommendation_snapshot->>'quote_line_id')::uuid,l.id,l.ordered_quantity_base FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=po.id;
       PERFORM public.recalculate_inventory_purchase_order_totals(po.id);
       UPDATE public.inventory_purchase_orders SET status='ordered',approval_snapshot_version=1,document_status='pending',
         approval_snapshot=jsonb_build_object('order',(SELECT to_jsonb(x) FROM public.inventory_purchase_orders x WHERE x.id=po.id),
           'supplier',(SELECT to_jsonb(s) FROM public.inventory_suppliers s WHERE s.id=po.supplier_id),
           'store',(SELECT to_jsonb(r) FROM public.restaurants r WHERE r.id=p_store_id),
           'lines',(SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',COALESCE(l.recommendation_snapshot->>'product_name',p.name),'specification',l.recommendation_snapshot->>'specification','receipt_classification',l.receipt_classification_snapshot) ORDER BY l.id)
             FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.purchase_order_id=po.id)) WHERE id=po.id RETURNING * INTO po;
       UPDATE public.inventory_purchase_orders SET approval_snapshot_hash=encode(extensions.digest(convert_to(approval_snapshot::text,'UTF8'),'sha256'),'hex')
         WHERE id=po.id RETURNING * INTO po;
       INSERT INTO public.inventory_purchase_documents(purchase_order_id,restaurant_id,snapshot_version,status) VALUES(po.id,p_store_id,1,'pending');
       IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active AND l.quantity_base>COALESCE((
         SELECT sum(quantity_base) FROM public.procurement_allocations WHERE request_line_id=l.id),0)) THEN UPDATE public.inventory_purchase_requests SET status='allocated' WHERE id=req.id; END IF;
       result:=jsonb_build_object('purchase_order',to_jsonb(po));
     ELSE RAISE EXCEPTION 'PROCUREMENT_ACTION_UNKNOWN';
     END CASE;
     UPDATE public.inventory_purchase_requests SET row_version=row_version+1,updated_at=now() WHERE id=req.id RETURNING * INTO req;
     result:=COALESCE(result,'{}'::jsonb)||to_jsonb(req);
   END IF;
 END IF;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason)
 VALUES(p_store_id,COALESCE((result->>'id')::uuid,p_record_id,p_store_id),p_action,actor,old_state,result,command_reason);
 INSERT INTO public.procurement_command_results(restaurant_id,idempotency_key,actor_key,payload_hash,result)
 VALUES(p_store_id,p_idempotency_key,actor_key,input_hash,result);
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.capture_inventory_order_line_terms()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE item public.inventory_supplier_items%rowtype; state text; product public.inventory_products%rowtype;
BEGIN
 SELECT status INTO state FROM public.inventory_purchase_orders WHERE id=NEW.purchase_order_id;
 IF TG_OP='UPDATE' AND COALESCE(current_setting('app.procurement_terms_repair',true),'')<>'true' AND state NOT IN ('draft','submitted','office_returned') AND (
   NEW.ordered_quantity_base IS DISTINCT FROM OLD.ordered_quantity_base
   OR NEW.ordered_quantity_unit IS DISTINCT FROM OLD.ordered_quantity_unit
   OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
   OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount
   OR NEW.order_unit_quantity_base_snapshot IS DISTINCT FROM OLD.order_unit_quantity_base_snapshot
   OR NEW.tax_rate_snapshot IS DISTINCT FROM OLD.tax_rate_snapshot
   OR NEW.product_id IS DISTINCT FROM OLD.product_id
   OR NEW.receipt_classification_snapshot IS DISTINCT FROM OLD.receipt_classification_snapshot
   OR NEW.base_unit_snapshot IS DISTINCT FROM OLD.base_unit_snapshot
   OR NEW.order_unit IS DISTINCT FROM OLD.order_unit
   OR NEW.supply_amount IS DISTINCT FROM OLD.supply_amount
   OR NEW.supplier_item_id IS DISTINCT FROM OLD.supplier_item_id
 ) THEN RAISE EXCEPTION 'INVENTORY_ORDER_TERMS_IMMUTABLE'; END IF;
 IF TG_OP='INSERT' OR state IN ('draft','submitted','office_returned') THEN
   SELECT * INTO item FROM public.inventory_supplier_items WHERE id=NEW.supplier_item_id;
   SELECT * INTO product FROM public.inventory_products WHERE id=NEW.product_id;
   NEW.order_unit_quantity_base_snapshot:=COALESCE(
     NULLIF(NEW.ordered_quantity_base,0)/NULLIF(NEW.ordered_quantity_unit,0),item.order_unit_quantity_base);
   NEW.tax_rate_snapshot:=COALESCE(CASE
     WHEN NEW.recommendation_snapshot->>'tax_rate' ~ '^[0-9]+(\.[0-9]+)?$'
       THEN (NEW.recommendation_snapshot->>'tax_rate')::numeric END,item.tax_rate);
   NEW.base_unit_snapshot:=product.base_unit;
   NEW.receipt_classification_snapshot:=COALESCE(NEW.recommendation_snapshot->>'receipt_classification',product.receipt_classification);
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.verify_inventory_receipt_p1(
  p_receipt_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_lines jsonb DEFAULT '[]'::jsonb,
  p_verification_reason text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_receipt public.inventory_receipts%ROWTYPE;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line jsonb;
  v_receipt_line public.inventory_receipt_lines%ROWTYPE;
  v_order_line public.inventory_purchase_order_lines%ROWTYPE;
  v_accepted numeric(12,3);
  v_rejected numeric(12,3);
  v_price numeric(12,2);
  v_reason text;
  v_conversion numeric(12,3);
  v_unit_quantity numeric(12,3);
  v_tax_rate numeric(5,2);
  v_supply numeric(12,2) := 0;
  v_tax numeric(12,2) := 0;
  v_ordered_total numeric(12,3);
  v_accepted_before numeric(12,3);
  v_accepted_after numeric(12,3);
  v_previous public.inventory_receipt_confirmation_attempts%ROWTYPE;
  v_payload_hash text;
  v_attempt_key text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
BEGIN
  IF v_attempt_key IS NULL THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_receipt.purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id FOR UPDATE;
  IF NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN';
  END IF;
  IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS (
    SELECT 1 FROM public.inventory_receipt_submission_attempts a
    WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid()) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED';
  END IF;
  v_payload_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'receipt_id',p_receipt_id,'lines',COALESCE(p_lines,'[]'::jsonb),
    'reason',NULLIF(btrim(p_verification_reason),'')
  )::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_previous FROM public.inventory_receipt_confirmation_attempts
    WHERE purchase_order_id=v_order.id AND attempt_key=v_attempt_key;
  IF FOUND THEN
    IF v_previous.receipt_id IS DISTINCT FROM p_receipt_id
       OR v_previous.actor_id IS DISTINCT FROM auth.uid()
       OR v_previous.metadata->>'payload_hash' IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_RETRY_MISMATCH';
    END IF;
    RETURN v_order;
  END IF;
  IF v_receipt.status = 'confirmed' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_ALREADY_CONFIRMED';
  END IF;
  IF v_receipt.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_VERIFIABLE'; END IF;
  IF v_receipt.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  PERFORM public.validate_inventory_receipt_attachment(
    v_receipt.restaurant_id, v_receipt.id, v_receipt.statement_storage_path, v_receipt.inspector_name);
  IF v_receipt.submitted_at IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_REQUIRED';
  END IF;

  SELECT COALESCE(sum(ordered_quantity_base), 0) INTO v_ordered_total
  FROM public.inventory_purchase_order_lines WHERE purchase_order_id = v_order.id;
  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_before
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array'
     AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      SELECT * INTO v_receipt_line FROM public.inventory_receipt_lines
      WHERE receipt_id = v_receipt.id
        AND purchase_order_line_id = NULLIF(
          v_line->>'purchase_order_line_id', ''
        )::uuid FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_NOT_FOUND'; END IF;
      SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
      WHERE id = v_receipt_line.purchase_order_line_id;
      v_accepted := COALESCE(
        NULLIF(v_line->>'accepted_quantity_base', '')::numeric,
        v_receipt_line.accepted_quantity_base
      );
      v_rejected := COALESCE(
        NULLIF(v_line->>'rejected_quantity_base', '')::numeric,
        v_receipt_line.rejected_quantity_base
      );
      v_price := COALESCE(
        NULLIF(v_line->>'actual_unit_price', '')::numeric,
        v_receipt_line.actual_unit_price, v_order_line.unit_price
      );
      v_reason := COALESCE(
        NULLIF(btrim(COALESCE(v_line->>'discrepancy_reason', '')), ''),
        v_receipt_line.discrepancy_reason
      );
      IF v_accepted < 0 OR v_rejected < 0 OR v_price < 0
         OR v_accepted::text IN ('NaN','Infinity','-Infinity')
         OR v_rejected::text IN ('NaN','Infinity','-Infinity')
         OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_FINAL_VALUE_INVALID';
      END IF;
      IF (v_accepted IS DISTINCT FROM v_receipt_line.accepted_quantity_base
          OR v_price IS DISTINCT FROM v_order_line.unit_price)
         AND v_reason IS NULL THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED';
      END IF;
      UPDATE public.inventory_receipt_lines SET
        received_quantity_base = v_accepted + v_rejected,
        accepted_quantity_base = v_accepted,
        rejected_quantity_base = v_rejected,
        actual_unit_price = v_price,
        discrepancy_reason = v_reason,
        updated_at = now()
      WHERE id = v_receipt_line.id;
    END LOOP;
  END IF;

  v_receipt.total_supply_amount := 0;
  v_receipt.tax_amount := 0;
  FOR v_receipt_line IN
    SELECT * FROM public.inventory_receipt_lines
    WHERE receipt_id = v_receipt.id FOR UPDATE
  LOOP
    SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
    WHERE id = v_receipt_line.purchase_order_line_id;
    v_conversion := v_order_line.order_unit_quantity_base_snapshot;
    v_tax_rate := v_order_line.tax_rate_snapshot;
    IF v_conversion IS NULL OR v_conversion <= 0 OR v_tax_rate IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_ORDER_TERMS_REVIEW_REQUIRED';
    END IF;
    v_unit_quantity := v_receipt_line.accepted_quantity_base / v_conversion;
    UPDATE public.inventory_receipt_lines SET
      actual_unit_price = COALESCE(actual_unit_price, v_order_line.unit_price),
      final_supply_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price), 2),
      final_tax_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price) * v_tax_rate / 100, 2),
      updated_at = now()
    WHERE id = v_receipt_line.id
    RETURNING final_supply_amount, final_tax_amount INTO v_supply, v_tax;
    v_receipt.total_supply_amount := v_receipt.total_supply_amount + v_supply;
    v_receipt.tax_amount := v_receipt.tax_amount + v_tax;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.inventory_receipt_lines rl
    LEFT JOIN public.inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id
    LEFT JOIN public.inventory_products pr ON pr.id=rl.product_id
    LEFT JOIN public.inventory_items it ON it.id=pr.inventory_item_id
    WHERE rl.receipt_id=v_receipt.id AND rl.accepted_quantity_base>0
      AND (ol.id IS NULL OR ol.purchase_order_id<>v_order.id
        OR ol.product_id<>rl.product_id OR pr.restaurant_id<>v_order.restaurant_id
        OR (ol.receipt_classification_snapshot='stock' AND (it.id IS NULL OR it.restaurant_id<>v_order.restaurant_id)))
  ) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STOCK_MAPPING_REQUIRED'; END IF;

  IF v_order.workflow_version=2 AND EXISTS(WITH accepted AS (
    SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l
    JOIN public.inventory_receipts r ON r.id=l.receipt_id AND r.status='confirmed' WHERE r.purchase_order_id=v_order.id GROUP BY l.purchase_order_line_id)
    SELECT 1 FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id
    LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id WHERE l.receipt_id=v_receipt.id
    AND l.accepted_quantity_base>ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(a.qty,0)) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCEPTED_EXCEEDS_REMAINING'; END IF;

  UPDATE public.inventory_items ii SET
    current_stock = COALESCE(ii.current_stock, 0) + received.accepted_quantity_base,
    quantity = COALESCE(ii.quantity, 0) + received.accepted_quantity_base,
    updated_at = now()
  FROM (
    SELECT ip.inventory_item_id,
      sum(irl.accepted_quantity_base) accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip ON ip.id = irl.product_id
    JOIN public.inventory_purchase_order_lines ol ON ol.id=irl.purchase_order_line_id AND ol.receipt_classification_snapshot='stock'
    WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  INSERT INTO public.inventory_transactions(
    restaurant_id, ingredient_id, transaction_type, quantity_g,
    reference_type, reference_id, note, created_by
  )
  SELECT v_order.restaurant_id, ip.inventory_item_id, 'restock',
    sum(irl.accepted_quantity_base), 'inventory_purchase_receipt', v_receipt.id,
    'Verified supplier statement ' || COALESCE(v_receipt.statement_number, v_receipt.id::text), auth.uid()
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_products ip ON ip.id = irl.product_id
    JOIN public.inventory_purchase_order_lines ol ON ol.id=irl.purchase_order_line_id AND ol.receipt_classification_snapshot='stock'
  WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    AND irl.accepted_quantity_base > 0
  GROUP BY ip.inventory_item_id;

  UPDATE public.inventory_receipts SET
    status = 'confirmed', verified_by = auth.uid(), verified_at = now(),
    total_supply_amount = v_receipt.total_supply_amount,
    tax_amount = v_receipt.tax_amount,
    total_amount = v_receipt.total_supply_amount + v_receipt.tax_amount,
    verification_reason = NULLIF(btrim(COALESCE(p_verification_reason, '')), ''),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_receipt.id RETURNING * INTO v_receipt;

  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_after
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  UPDATE public.inventory_purchase_orders SET
    status = CASE WHEN NOT EXISTS (
      SELECT 1 FROM public.inventory_purchase_order_lines pol
      WHERE pol.purchase_order_id=v_order.id
        AND pol.ordered_quantity_base-pol.cancelled_quantity_base > COALESCE((
          SELECT sum(rl.accepted_quantity_base) FROM public.inventory_receipt_lines rl
          JOIN public.inventory_receipts r ON r.id=rl.receipt_id
          WHERE rl.purchase_order_line_id=pol.id AND r.status='confirmed'
        ),0)
    ) THEN 'received' ELSE 'partially_received' END,
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;

  INSERT INTO public.inventory_receipt_confirmation_attempts(
    purchase_order_id, receipt_id, restaurant_id, actor_id, attempt_key,
    attempt_status, requested_line_count, accepted_total_quantity_base,
    rejected_total_quantity_base, remaining_quantity_before_base,
    remaining_quantity_after_base, metadata
  ) SELECT
    v_order.id, v_receipt.id, v_order.restaurant_id, auth.uid(), v_attempt_key,
    'succeeded', count(*)::integer,
    COALESCE(sum(accepted_quantity_base), 0),
    COALESCE(sum(rejected_quantity_base), 0),
    GREATEST(v_ordered_total - v_accepted_before, 0),
    GREATEST(v_ordered_total - v_accepted_after, 0),
    jsonb_build_object(
      'payload_hash',v_payload_hash,'maker_checker', true, 'statement_number', v_receipt.statement_number,
      'order_status_after', v_order.status,
      'total_amount', v_receipt.total_amount
    )
  FROM public.inventory_receipt_lines WHERE receipt_id = v_receipt.id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'inventory_receipt_verified', 'inventory_purchase_order',
    v_order.id, jsonb_build_object(
      'receipt_id', v_receipt.id,
      'statement_number', v_receipt.statement_number,
      'total_amount', v_receipt.total_amount,
      'order_status_after', v_order.status
    )
  );
  RETURN v_order;
END;
$$;
CREATE OR REPLACE FUNCTION public.submit_inventory_receipt_batch(
  p_purchase_order_id uuid,p_receipt_id uuid,p_expected_order_version integer,
  p_expected_receipt_version integer,p_idempotency_key text,p_lines jsonb,
  p_inspector_name text,p_statement_storage_path text,
  p_statement_number text DEFAULT NULL,p_statement_date date DEFAULT NULL,p_memo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE; v_receipt public.inventory_receipts%ROWTYPE;
  v_line jsonb; v_po_line public.inventory_purchase_order_lines%ROWTYPE;
  v_qty numeric; v_rejected numeric; v_price numeric; v_ids uuid[]:=ARRAY[]::uuid[];
  v_hash text; v_previous public.inventory_receipt_submission_attempts%ROWTYPE;
  v_result jsonb; v_total numeric:=0; photo jsonb; v_remaining numeric;
BEGIN
  IF p_receipt_id IS NULL OR NULLIF(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_FORBIDDEN'; END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('order',p_purchase_order_id,
    'lines',p_lines,'inspector',p_inspector_name,'file',p_statement_storage_path,
    'number',p_statement_number,'date',p_statement_date,'memo',p_memo)::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_previous FROM public.inventory_receipt_submission_attempts
    WHERE receipt_id=p_receipt_id AND attempt_key=p_idempotency_key;
  IF FOUND THEN
    IF v_previous.actor_id<>auth.uid() OR v_previous.payload_hash<>v_hash THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_RETRY_MISMATCH'; END IF;
    RETURN v_previous.result;
  END IF;
  IF v_order.workflow_version=2 AND v_order.procurement_status<>'confirmed' THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_CONFIRMATION_REQUIRED'; END IF;
  IF v_order.status NOT IN ('ordered','partially_received','office_approved') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_order_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.purchase_order_id<>v_order.id OR v_receipt.status<>'draft' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_EDITABLE'; END IF;
    IF v_receipt.row_version IS DISTINCT FROM p_expected_receipt_version THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    IF v_receipt.received_by IS DISTINCT FROM auth.uid() AND public.inventory_purchase_actor_role()='inventory_orderer' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED'; END IF;
  ELSE
    IF COALESCE(p_expected_receipt_version,0)<>0 OR EXISTS (
      SELECT 1 FROM public.inventory_receipts WHERE purchase_order_id=v_order.id AND status='draft') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,received_by,status,delivery_cycle)
      SELECT p_receipt_id,v_order.id,v_order.restaurant_id,v_order.supplier_id,auth.uid(),'draft',COALESCE(max(delivery_cycle),0)+1
      FROM public.inventory_receipts WHERE purchase_order_id=v_order.id RETURNING * INTO v_receipt;
  END IF;
  PERFORM public.validate_inventory_receipt_attachment(v_order.restaurant_id,p_receipt_id,p_statement_storage_path,p_inspector_name);
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_po_line FROM public.inventory_purchase_order_lines
      WHERE id=(v_line->>'purchase_order_line_id')::uuid AND purchase_order_id=v_order.id FOR UPDATE;
    IF NOT FOUND OR v_po_line.id=ANY(v_ids) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_INVALID'; END IF;
    v_ids:=array_append(v_ids,v_po_line.id);
    v_qty:=NULLIF(v_line->>'received_quantity_base','')::numeric;
    v_rejected:=COALESCE(NULLIF(v_line->>'rejected_quantity_base','')::numeric,0);
    v_price:=COALESCE(NULLIF(v_line->>'actual_unit_price','')::numeric,v_po_line.unit_price);
    IF v_qty IS NULL OR v_qty<0 OR v_rejected<0 OR v_rejected>v_qty OR v_price<0
      OR v_rejected::text IN ('NaN','Infinity','-Infinity')
      OR v_qty::text IN ('NaN','Infinity','-Infinity') OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_QUANTITY_INVALID'; END IF;
    SELECT greatest(0,v_po_line.ordered_quantity_base-v_po_line.cancelled_quantity_base-COALESCE(sum(l.accepted_quantity_base),0)) INTO v_remaining
      FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
      WHERE l.purchase_order_line_id=v_po_line.id AND r.status='confirmed';
    IF (v_qty<>v_remaining OR v_price<>v_po_line.unit_price)
      AND NULLIF(btrim(v_line->>'discrepancy_reason'),'') IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED'; END IF;
    IF v_order.workflow_version=2 THEN
      PERFORM public.validate_procurement_inspection(v_po_line.product_id,v_line->'inspection',v_qty-v_rejected);
      IF jsonb_typeof(v_line->'inspection'->'photo_paths') IS DISTINCT FROM 'array' OR jsonb_array_length(v_line->'inspection'->'photo_paths')>5 THEN RAISE EXCEPTION 'PROCUREMENT_PHOTOS_INVALID'; END IF;
      FOR photo IN SELECT * FROM jsonb_array_elements(v_line->'inspection'->'photo_paths') LOOP
        PERFORM public.validate_inventory_receipt_attachment(v_order.restaurant_id,p_receipt_id,photo#>>'{}',p_inspector_name);
      END LOOP;
      IF v_rejected>0 AND COALESCE(v_line->'inspection'->>'issue_type','none')='none' THEN RAISE EXCEPTION 'PROCUREMENT_ISSUE_TYPE_REQUIRED'; END IF;
    END IF;
    v_total:=v_total+v_qty;
    INSERT INTO public.inventory_receipt_lines(receipt_id,purchase_order_line_id,product_id,
      received_quantity_base,accepted_quantity_base,rejected_quantity_base,actual_unit_price,discrepancy_reason,inspection,expected_quantity_base_snapshot)
    VALUES (p_receipt_id,v_po_line.id,v_po_line.product_id,v_qty,v_qty-v_rejected,v_rejected,v_price,
      NULLIF(btrim(v_line->>'discrepancy_reason'),''),COALESCE(v_line->'inspection','{}'),v_remaining)
    ON CONFLICT (receipt_id,purchase_order_line_id) WHERE purchase_order_line_id IS NOT NULL
    DO UPDATE SET received_quantity_base=EXCLUDED.received_quantity_base,
      accepted_quantity_base=EXCLUDED.accepted_quantity_base,rejected_quantity_base=EXCLUDED.rejected_quantity_base,
      actual_unit_price=EXCLUDED.actual_unit_price,discrepancy_reason=EXCLUDED.discrepancy_reason,inspection=EXCLUDED.inspection,expected_quantity_base_snapshot=EXCLUDED.expected_quantity_base_snapshot,updated_at=now();
  END LOOP;
  IF cardinality(v_ids)<>(SELECT count(*) FROM public.inventory_purchase_order_lines WHERE purchase_order_id=v_order.id)
     OR v_total<=0 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  UPDATE public.inventory_receipts SET inspector_name=btrim(p_inspector_name),statement_storage_path=p_statement_storage_path,
    statement_number=NULLIF(btrim(p_statement_number),''),statement_date=p_statement_date,
    memo=NULLIF(btrim(p_memo),''),submitted_at=now(),row_version=row_version+1,updated_at=now()
    WHERE id=p_receipt_id RETURNING * INTO v_receipt;
  v_result:=jsonb_build_object('receipt_id',p_receipt_id,'row_version',v_receipt.row_version,'status',v_receipt.status);
  INSERT INTO public.inventory_receipt_submission_attempts(receipt_id,attempt_key,actor_id,payload_hash,result)
    VALUES(p_receipt_id,p_idempotency_key,auth.uid(),v_hash,v_result);
  RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.verify_inventory_receipt(p_receipt_id uuid,p_expected_version integer,p_idempotency_key text,
 p_lines jsonb DEFAULT '[]',p_verification_reason text DEFAULT NULL)
RETURNS public.inventory_purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE po public.inventory_purchase_orders%rowtype; result public.inventory_purchase_orders%rowtype; rl record; item jsonb; accepted numeric;
 saved_write text:=current_setting('app.procurement_write',true);
BEGIN
 SELECT o.* INTO po FROM public.inventory_purchase_orders o JOIN public.inventory_receipts r ON r.purchase_order_id=o.id WHERE r.id=p_receipt_id FOR UPDATE OF o;
 IF po.workflow_version=2 AND po.procurement_status<>'confirmed' THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_CONFIRMATION_REQUIRED'; END IF;
 IF po.workflow_version=2 AND EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=p_receipt_id AND status='draft') THEN
   FOR rl IN SELECT * FROM public.inventory_receipt_lines WHERE receipt_id=p_receipt_id LOOP
     SELECT e INTO item FROM jsonb_array_elements(p_lines) e WHERE e->>'purchase_order_line_id'=rl.purchase_order_line_id::text;
     accepted:=COALESCE((item->>'accepted_quantity_base')::numeric,rl.accepted_quantity_base);
     IF accepted>rl.received_quantity_base THEN RAISE EXCEPTION 'PROCUREMENT_ACCEPTED_EXCEEDS_RECEIVED'; END IF;
     PERFORM public.validate_procurement_inspection(rl.product_id,rl.inspection,accepted);
   END LOOP;
 END IF;
 PERFORM set_config('app.procurement_write','true',true);
 result:=public.verify_inventory_receipt_p1(p_receipt_id,p_expected_version,p_idempotency_key,p_lines,p_verification_reason);
 IF po.workflow_version=2 THEN
   INSERT INTO public.inventory_receipt_issues(restaurant_id,receipt_line_id,purchase_order_id,issue_type,ordered_quantity_base,received_quantity_base,accepted_quantity_base,reason)
   SELECT po.restaurant_id,l.id,po.id,CASE WHEN l.inspection->>'issue_type'<>'none' THEN l.inspection->>'issue_type'
     WHEN l.received_quantity_base>COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base) THEN 'excess' ELSE 'shortage' END,
     COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base),l.received_quantity_base,l.accepted_quantity_base,l.discrepancy_reason
   FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id
   WHERE l.receipt_id=p_receipt_id AND (l.received_quantity_base<>COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base) OR l.rejected_quantity_base>0 OR COALESCE(l.inspection->>'issue_type','none')<>'none')
   ON CONFLICT(receipt_line_id) DO NOTHING;
 END IF;
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 RETURN result;
END $$;

COMMIT;
