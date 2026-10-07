-- PR-account feedback: bounded PR views, automatic estimate source, and beverage category.
-- Existing Office callers retain updated-at cursors unless request_sort='created' is explicit.
BEGIN;
-- Recheck the predecessor inside the apply transaction as well as in preflight.
DO $$ BEGIN
 IF encode(extensions.digest(pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure),'sha256'),'hex')<>'5c6525903b5b5ba303ee197ae0389e89af2e86dc8116ea761e57ebcd78469e65'
 OR encode(extensions.digest(pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure),'sha256'),'hex')<>'1dbd7698d562a7d7d2a585330f7fdeeca691f3c7295a24e8cab5e6bdd1abd866'
 OR encode(extensions.digest(pg_get_functiondef('public.procurement_document_data(uuid,text,uuid,text,jsonb)'::regprocedure),'sha256'),'hex')<>'1d12cd1c88e71599bc1938a0af3b652f3ced81423bc8add1bc8cd4bac7d7c2db' THEN RAISE EXCEPTION 'PROCUREMENT_PR_PREDECESSOR_CHANGED'; END IF;
 IF to_regclass('public.procurement_requests_store_created') IS NOT NULL
 OR position('beverage' IN pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conrelid='public.inventory_purchase_requests'::regclass AND conname='inventory_purchase_requests_purchase_category_check')))>0
 OR NOT has_function_privilege('authenticated','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)','EXECUTE')
 OR position('combined_receiving_inspection' IN pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure))=0
 THEN RAISE EXCEPTION 'PROCUREMENT_PR_PRECONDITION_FAILED'; END IF;
END $$;
ALTER TABLE public.inventory_purchase_requests DROP CONSTRAINT inventory_purchase_requests_purchase_category_check;
ALTER TABLE public.inventory_purchase_requests ADD CONSTRAINT inventory_purchase_requests_purchase_category_check
 CHECK(purchase_category IN ('raw_material','tools','stationery','beverage','other'));
CREATE INDEX procurement_requests_store_created ON public.inventory_purchase_requests(restaurant_id,created_at DESC,id DESC);

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
 advance_payment public.procurement_channel_payments%rowtype; employee_id uuid;
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
     employee_id:=NULLIF(p_payload->>'office_employee_id','')::uuid;
     IF p_payload->>'paid_by'='employee' THEN
       IF employee_id IS NULL OR p_payload->'employee_confirmation'->>'employee_id' IS DISTINCT FROM employee_id::text
          OR p_payload->'employee_confirmation'->>'pos_store_id' IS DISTINCT FROM p_store_id::text THEN RAISE EXCEPTION 'PROCUREMENT_EMPLOYEE_MAPPING_REQUIRED'; END IF;
     ELSIF employee_id IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_EMPLOYEE_OWNER_INVALID'; END IF;
     IF p_payload->>'kind' IN ('refund','reimbursement') THEN
       SELECT * INTO advance_payment FROM public.procurement_channel_payments
       WHERE id=NULLIF(p_payload->>'advance_payment_id','')::uuid AND purchase_order_id=po.id AND kind='advance' FOR UPDATE;
       IF NOT FOUND OR advance_payment.paid_by IS DISTINCT FROM p_payload->>'paid_by'
          OR advance_payment.office_employee_id IS DISTINCT FROM employee_id THEN RAISE EXCEPTION 'PROCUREMENT_ADVANCE_OWNER_REQUIRED'; END IF;
       SELECT advance_payment.amount-COALESCE(sum(amount),0) INTO total FROM public.procurement_channel_payments
       WHERE advance_payment_id=advance_payment.id AND kind IN ('refund','reimbursement');
       IF v_quantity>total THEN RAISE EXCEPTION 'PROCUREMENT_SETTLEMENT_EXCEEDS_ADVANCE'; END IF;
       IF p_payload->>'kind'='reimbursement' AND p_payload->>'paid_by' IS DISTINCT FROM 'employee' THEN RAISE EXCEPTION 'PROCUREMENT_REIMBURSEMENT_OWNER_INVALID'; END IF;
     END IF;
     old_state:=to_jsonb(po);
     INSERT INTO public.procurement_channel_payments(restaurant_id,purchase_order_id,external_order_no,kind,paid_by,amount,payment_reference,evidence_reference,actor,office_employee_id,advance_payment_id)
       VALUES(p_store_id,po.id,p_payload->>'external_order_no',p_payload->>'kind',p_payload->>'paid_by',v_quantity,p_payload->>'payment_reference',p_payload->>'evidence_reference',actor,employee_id,advance_payment.id);
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
         purchase_category=COALESCE(p_payload->>'purchase_category',req.purchase_category),purchase_channel=COALESCE(p_payload->>'purchase_channel',req.purchase_channel) WHERE id=req.id RETURNING * INTO req;
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
     WITH eligible AS MATERIALIZED (
       SELECT si.* FROM public.inventory_supplier_items si
       JOIN public.inventory_products p ON p.id=si.product_id AND p.restaurant_id=p_store_id
       JOIN public.inventory_suppliers s ON s.id=si.supplier_id AND s.status='active'
         AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))
       WHERE si.is_active AND si.product_id IN (SELECT (x->>'product_id')::uuid FROM jsonb_array_elements(p_payload->'lines') x)
     ), estimates AS (
       SELECT DISTINCT ON (product_id,supplier_id) * FROM eligible ORDER BY product_id,supplier_id,is_preferred DESC,id
     ), ranked AS (
       SELECT e.*,dense_rank() OVER(PARTITION BY product_id ORDER BY is_preferred DESC) priority FROM eligible e
     ), preferred AS (
       SELECT r.*,count(*) OVER(PARTITION BY product_id) choices FROM ranked r WHERE priority=1
     ), defaults AS (SELECT * FROM preferred WHERE choices=1)
     SELECT req.id,p.id,(x->>'quantity')::numeric,x->>'unit',
       (x->>'quantity')::numeric*CASE WHEN x->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,
       CASE WHEN x->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,it.current_stock,it.updated_at,
       NULLIF(x->>'preferred_supplier_id','')::uuid,x->>'memo',p.name,p.specification,p.receipt_classification,
       CASE WHEN NULLIF(x->>'preferred_supplier_id','') IS NULL THEN d.unit_price ELSE e.unit_price END,
       CASE WHEN NULLIF(x->>'preferred_supplier_id','') IS NULL THEN d.tax_rate ELSE e.tax_rate END,
       CASE WHEN NULLIF(x->>'preferred_supplier_id','') IS NULL THEN d.order_unit_quantity_base ELSE e.order_unit_quantity_base END,
       CASE WHEN NULLIF(x->>'preferred_supplier_id','') IS NULL THEN d.order_unit ELSE e.order_unit END,
       CASE WHEN NULLIF(x->>'preferred_supplier_id','') IS NULL THEN d.id ELSE e.id END
     FROM jsonb_array_elements(p_payload->'lines') x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
     LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
     LEFT JOIN estimates e ON e.product_id=p.id AND e.supplier_id=NULLIF(x->>'preferred_supplier_id','')::uuid
     LEFT JOIN defaults d ON d.product_id=p.id;
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

CREATE OR REPLACE FUNCTION public.procurement_workspace_page_core(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;policy jsonb;prices boolean;estimates boolean;lim integer;result jsonb;requests jsonb;orders jsonb;catalog jsonb;request_counts jsonb;
 created_sort boolean:=p_query->>'request_sort'='created';
 rid uuid:=NULLIF(p_query->>'request_id','')::uuid;oid uuid:=NULLIF(p_query->>'order_id','')::uuid;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);prices:=COALESCE((actor->>'can_view_prices')::boolean,false);
 SELECT to_jsonb(p) INTO policy FROM public.procurement_store_policies p WHERE restaurant_id=p_store_id;
 estimates:=prices OR COALESCE((policy->>'three_stage_required')::boolean,false);
 IF NULLIF(p_query->>'purchase_category','') IS NOT NULL AND p_query->>'purchase_category' NOT IN ('raw_material','tools','stationery','beverage','other') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF NULLIF(p_query->>'request_group','') IS NOT NULL AND p_query->>'request_group' NOT IN ('pending','approved','cancelled') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF NULLIF(p_query->>'created_from','') IS NOT NULL AND NULLIF(p_query->>'created_to','') IS NOT NULL AND (p_query->>'created_from')::date>(p_query->>'created_to')::date THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 lim:=greatest(1,least(50,COALESCE((p_query->>'limit')::integer,20)));
 WITH filtered AS NOT MATERIALIZED (SELECT r.* FROM public.inventory_purchase_requests r WHERE r.restaurant_id=p_store_id
   AND(NULLIF(p_query->>'purchase_category','') IS NULL OR r.purchase_category=p_query->>'purchase_category'
     OR p_query->>'purchase_category'='tools' AND r.purchase_category='stationery')
   AND(NULLIF(p_query->>'search','') IS NULL OR r.request_no ILIKE '%'||(p_query->>'search')||'%' OR r.reason ILIKE '%'||(p_query->>'search')||'%')
   AND(NULLIF(p_query->>'created_from','') IS NULL OR r.created_at >= ((p_query->>'created_from')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
   AND(NULLIF(p_query->>'created_to','') IS NULL OR r.created_at < (((p_query->>'created_to')::date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
 ), page AS (SELECT r.* FROM filtered r
   WHERE(NULLIF(p_query->>'request_status','') IS NULL OR r.status=p_query->>'request_status')
   AND(NULLIF(p_query->>'request_group','') IS NULL
     OR p_query->>'request_group'='pending' AND r.status IN ('draft','returned','submitted','brand_review','office_review','senior_review')
     OR p_query->>'request_group'='approved' AND r.status IN ('approved','allocated')
     OR p_query->>'request_group'='cancelled' AND r.status='cancelled')
   AND (NULLIF(p_query->>'request_before','') IS NULL OR (CASE WHEN created_sort THEN r.created_at ELSE r.updated_at END,r.id)<((p_query->>'request_before')::timestamptz,(p_query->>'request_before_id')::uuid))
   ORDER BY CASE WHEN created_sort THEN r.created_at ELSE r.updated_at END DESC,r.id DESC LIMIT lim+1), counts AS (
   SELECT l.request_id,count(*) line_count,sum(l.quantity_base) quantity_base FROM public.inventory_purchase_request_lines l JOIN page p ON p.id=l.request_id WHERE l.active GROUP BY l.request_id)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'request_no',p.request_no,'status',p.status,'row_version',p.row_version,'reason',p.reason,
   'created_at',p.created_at,'updated_at',p.updated_at,'submitted_at',p.submitted_at,'requested_delivery_date',p.requested_delivery_date,
   'purchase_category',p.purchase_category,'purchase_channel',p.purchase_channel,'approval_policy_version',p.approval_policy_version,
   'line_count',COALESCE(c.line_count,0),'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN public.procurement_allowed_actions(p,actor) ELSE '[]' END,
   'lines','[]'::jsonb,'quotes','[]'::jsonb) ORDER BY CASE WHEN created_sort THEN p.created_at ELSE p.updated_at END DESC,p.id DESC),'[]'),
   (SELECT jsonb_build_object('pending',count(*) FILTER(WHERE status IN ('draft','returned','submitted','brand_review','office_review','senior_review')),
    'approved',count(*) FILTER(WHERE status IN ('approved','allocated')),'cancelled',count(*) FILTER(WHERE status='cancelled')) FROM filtered)
 INTO requests,request_counts FROM page p LEFT JOIN counts c ON c.request_id=p.id;
 WITH page AS (SELECT po.* FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.workflow_version=2
   AND(NOT COALESCE((p_query->>'request_view')::boolean,false) OR rid IS NOT NULL)
   AND(rid IS NULL OR po.commercial_terms->>'request_id'=rid::text)
   AND(NULLIF(p_query->>'search','') IS NULL OR po.purchase_order_no ILIKE '%'||(p_query->>'search')||'%' OR po.commercial_terms->>'pr_no' ILIKE '%'||(p_query->>'search')||'%')
   AND (NULLIF(p_query->>'order_before','') IS NULL OR (po.created_at,po.id)<((p_query->>'order_before')::timestamptz,(p_query->>'order_before_id')::uuid))
   ORDER BY po.created_at DESC,po.id DESC LIMIT lim+1)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'purchase_order_no',p.purchase_order_no,'status',p.status,'procurement_status',p.procurement_status,
   'row_version',p.row_version,'created_at',p.created_at,'requested_delivery_date',p.requested_delivery_date,'commercial_revision',p.commercial_revision,
   'supplier_name',s.supplier_name,'pr_no',p.commercial_terms->'pr_no','pr_created_at',p.commercial_terms->'pr_created_at','pr_submitted_at',p.commercial_terms->'pr_submitted_at',
   'issued_at',p.commercial_terms->'issued_at','accounting_status',to_jsonb(a)||jsonb_build_object('stale',a.observed_at<now()-interval '10 minutes' OR a.source_order_version<>p.row_version),'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) AND COALESCE((actor->>'can_office_approve')::boolean,false)
     THEN CASE p.procurement_status WHEN 'issued' THEN '["send_po"]'::jsonb WHEN 'sent' THEN '["confirm_po"]'::jsonb ELSE '[]'::jsonb END ELSE '[]'::jsonb END) ORDER BY p.created_at DESC,p.id DESC),'[]')
 INTO orders FROM page p LEFT JOIN public.inventory_suppliers s ON s.id=p.supplier_id LEFT JOIN public.procurement_accounting_status a ON a.purchase_order_id=p.id;
 WITH products AS (SELECT p.*,it.current_stock,it.updated_at stock_updated_at FROM public.inventory_products p
   LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
   WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
   AND (NULLIF(p_query->>'catalog_after','') IS NULL OR p.id>(p_query->>'catalog_after')::uuid)
   AND (NULLIF(p_query->>'catalog_search','') IS NULL OR p.name ILIKE '%'||(p_query->>'catalog_search')||'%' OR EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=rid AND l.product_id=p.id AND l.active)) ORDER BY CASE WHEN EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=rid AND l.product_id=p.id AND l.active) THEN 0 ELSE 1 END,p.id LIMIT 201)
 SELECT jsonb_build_object('products',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'specification',p.specification,
   'receipt_classification',p.receipt_classification,'stock_unit',p.stock_unit,'base_unit',p.base_unit,'conversion',p.base_unit_factor,'current_stock',p.current_stock,'stock_updated_at',p.stock_updated_at) ORDER BY p.id) FROM (SELECT * FROM products LIMIT 200) p),'[]'),
   'catalog_has_more',(SELECT count(*)>200 FROM products),'supplier_items',COALESCE((SELECT jsonb_agg(
     (CASE WHEN estimates THEN to_jsonb(si) ELSE to_jsonb(si)-'unit_price'-'tax_rate' END)||jsonb_build_object('supplier_name',s.supplier_name,'product_name',p.name,'payment_terms',s.payment_terms) ORDER BY si.product_id,si.id)
     FROM public.inventory_supplier_items si JOIN (SELECT * FROM products LIMIT 200) p ON p.id=si.product_id JOIN public.inventory_suppliers s ON s.id=si.supplier_id
     WHERE si.is_active AND s.status='active' AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))),'[]')) INTO catalog;
 result:=jsonb_build_object('contract_version',2,'read_contract','paged','store_id',p_store_id,'enabled',COALESCE((policy->>'enabled')::boolean,false),
   'actor',actor,'policy',policy,'requests',COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(requests) WITH ORDINALITY a(x,n) WHERE n<=lim),'[]'),
   'orders',COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(orders) WITH ORDINALITY a(x,n) WHERE n<=lim),'[]'),
   'request_counts',request_counts,'request_sort',CASE WHEN created_sort THEN 'created' ELSE 'updated' END,
   'request_has_more',jsonb_array_length(requests)>lim,'order_has_more',jsonb_array_length(orders)>lim,'events','[]'::jsonb,
   'receipts','[]'::jsonb,'issues','[]'::jsonb,'returns','[]'::jsonb)||catalog;
 IF rid IS NOT NULL THEN
   IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_requests WHERE id=rid AND restaurant_id=p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   WITH quote_page AS MATERIALIZED(SELECT * FROM public.procurement_quotes WHERE request_id=rid AND NOT archived
     AND(NULLIF(p_query->>'quote_before','') IS NULL OR(created_at,id)<((p_query->>'quote_before')::timestamptz,(p_query->>'quote_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 21), qlines AS (SELECT l.quote_id,jsonb_agg(to_jsonb(l) ORDER BY l.id) lines FROM public.procurement_quote_lines l JOIN (SELECT * FROM quote_page ORDER BY created_at DESC,id DESC LIMIT 20) q ON q.id=l.quote_id GROUP BY l.quote_id),
   quotes AS (SELECT jsonb_agg(to_jsonb(q)||jsonb_build_object('supplier_name',s.supplier_name,'lines',l.lines) ORDER BY q.created_at DESC,q.id DESC) rows
     FROM (SELECT * FROM quote_page ORDER BY created_at DESC,id DESC LIMIT 20) q JOIN public.inventory_suppliers s ON s.id=q.supplier_id LEFT JOIN qlines l ON l.quote_id=q.id WHERE q.request_id=rid AND NOT q.archived),
   lines AS (SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',COALESCE(l.product_name_snapshot,p.name)) ORDER BY l.id) rows FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.request_id=rid AND l.active)
   SELECT result||jsonb_build_object('quote_has_more',prices AND (SELECT count(*)>20 FROM quote_page),'request_detail',(CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'approved_amount' END)||jsonb_build_object('lines',COALESCE(l.rows,'[]'),'quotes',CASE WHEN prices THEN COALESCE(q.rows,'[]') ELSE '[]' END,
     'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN public.procurement_allowed_actions(r,actor) ELSE '[]' END)) INTO result FROM public.inventory_purchase_requests r CROSS JOIN quotes q CROSS JOIN lines l WHERE r.id=rid;
 END IF;
 IF oid IS NOT NULL THEN
   IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_orders WHERE id=oid AND restaurant_id=p_store_id AND workflow_version=2) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   SELECT result||jsonb_build_object('order_detail',(CASE WHEN prices THEN to_jsonb(po) ELSE to_jsonb(po)-'total_amount'-'total_supply_amount'-'tax_amount'-'approval_snapshot' END)||jsonb_build_object('supplier_name',s.supplier_name,'accounting_status',to_jsonb(a)||jsonb_build_object('stale',a.observed_at<now()-interval '10 minutes' OR a.source_order_version<>po.row_version),
     'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) AND COALESCE((actor->>'can_office_approve')::boolean,false) THEN CASE po.procurement_status WHEN 'issued' THEN '["send_po"]'::jsonb WHEN 'sent' THEN '["confirm_po"]'::jsonb ELSE '[]'::jsonb END ELSE '[]'::jsonb END))
   INTO result FROM public.inventory_purchase_orders po LEFT JOIN public.inventory_suppliers s ON s.id=po.supplier_id LEFT JOIN public.procurement_accounting_status a ON a.purchase_order_id=po.id WHERE po.id=oid;
   WITH receipt_page AS (SELECT * FROM public.inventory_receipts WHERE purchase_order_id=oid AND(NULLIF(p_query->>'receipt_before','') IS NULL OR(received_at,id)<((p_query->>'receipt_before')::timestamptz,(p_query->>'receipt_before_id')::uuid)) ORDER BY received_at DESC,id DESC LIMIT 21),
   lines AS (SELECT l.receipt_id,jsonb_agg((CASE WHEN prices THEN to_jsonb(l) ELSE to_jsonb(l)-'actual_unit_price'-'final_supply_amount'-'final_tax_amount' END)||jsonb_build_object('product_name',p.name) ORDER BY l.id) rows
     FROM public.inventory_receipt_lines l JOIN receipt_page r ON r.id=l.receipt_id JOIN public.inventory_products p ON p.id=l.product_id GROUP BY l.receipt_id)
   SELECT result||jsonb_build_object('receipt_has_more',(SELECT count(*)>20 FROM receipt_page),'receipts',COALESCE(jsonb_agg((CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'total_amount'-'total_supply_amount'-'tax_amount' END)||jsonb_build_object('lines',COALESCE(l.rows,'[]')) ORDER BY r.received_at DESC,r.id DESC),'[]')) INTO result FROM (SELECT * FROM receipt_page ORDER BY received_at DESC,id DESC LIMIT 20) r LEFT JOIN lines l ON l.receipt_id=r.id;
   WITH page AS(SELECT * FROM public.inventory_receipt_issues WHERE purchase_order_id=oid AND(NULLIF(p_query->>'issue_before','') IS NULL OR(created_at,id)<((p_query->>'issue_before')::timestamptz,(p_query->>'issue_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 51)
   SELECT result||jsonb_build_object('issue_has_more',(SELECT count(*)>50 FROM page),'issues',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 50) x),'[]')) INTO result;
   WITH page AS(SELECT * FROM public.inventory_supplier_returns WHERE purchase_order_id=oid AND(NULLIF(p_query->>'return_before','') IS NULL OR(created_at,id)<((p_query->>'return_before')::timestamptz,(p_query->>'return_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 51)
   SELECT result||jsonb_build_object('return_has_more',(SELECT count(*)>50 FROM page),'returns',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 50) x),'[]')) INTO result;

 END IF;
 IF rid IS NOT NULL OR oid IS NOT NULL THEN
   WITH page AS(SELECT ev.id,ev.record_id,ev.action,ev.actor,ev.reason,ev.created_at FROM public.procurement_events ev
     WHERE ev.restaurant_id=p_store_id AND ev.record_id IN(rid,oid) AND(NULLIF(p_query->>'event_before','') IS NULL OR(ev.created_at,ev.id)<((p_query->>'event_before')::timestamptz,(p_query->>'event_before_id')::uuid)) ORDER BY ev.created_at DESC,ev.id DESC LIMIT 101)
   SELECT result||jsonb_build_object('event_has_more',(SELECT count(*)>100 FROM page),'events',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 100) e),'[]')) INTO result;

 END IF;
 IF NULLIF(p_query->>'issue_followup_id','') IS NOT NULL THEN
   IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
   WITH issue AS(SELECT i.*,l.product_id,r.created_at received_at,po.supplier_id FROM public.inventory_receipt_issues i JOIN public.inventory_receipt_lines l ON l.id=i.receipt_line_id JOIN public.inventory_receipts r ON r.id=l.receipt_id JOIN public.inventory_purchase_orders po ON po.id=i.purchase_order_id
     WHERE i.id=(p_query->>'issue_followup_id')::uuid AND i.restaurant_id=p_store_id),
   candidates AS MATERIALIZED(SELECT l.id,l.accepted_quantity_base,r.created_at,r.received_at,r.statement_number,po.purchase_order_no,p.name product_name
     FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id JOIN public.inventory_purchase_orders po ON po.id=r.purchase_order_id JOIN public.inventory_products p ON p.id=l.product_id JOIN issue i ON i.product_id=l.product_id AND i.supplier_id=po.supplier_id
     WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND l.id<>i.receipt_line_id AND r.created_at>=i.received_at AND l.accepted_quantity_base>0
       AND(NULLIF(p_query->>'followup_search','') IS NULL OR po.purchase_order_no ILIKE '%'||(p_query->>'followup_search')||'%' OR r.statement_number ILIKE '%'||(p_query->>'followup_search')||'%')
       AND(NULLIF(p_query->>'followup_before','') IS NULL OR(r.created_at,l.id)<((p_query->>'followup_before')::timestamptz,(p_query->>'followup_before_id')::uuid)) ORDER BY r.created_at DESC,l.id DESC LIMIT 21),
   returned AS(SELECT t.receipt_line_id,sum(t.quantity_base) quantity FROM public.inventory_supplier_returns t JOIN candidates c ON c.id=t.receipt_line_id GROUP BY t.receipt_line_id)
   SELECT result||jsonb_build_object('followup_has_more',(SELECT count(*)>20 FROM candidates),'followup_receipt_lines',COALESCE(jsonb_agg(to_jsonb(c)||jsonb_build_object('net_accepted_quantity',c.accepted_quantity_base-COALESCE(t.quantity,0)) ORDER BY c.created_at DESC,c.id DESC),'[]')) INTO result
   FROM(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT 20)c LEFT JOIN returned t ON t.receipt_line_id=c.id;
 END IF;
 IF prices AND COALESCE((p_query->>'include_legacy')::boolean,false) THEN
   WITH page AS MATERIALIZED(SELECT po.* FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.workflow_version=1
     AND po.status IN ('ordered','partially_received','office_approved') AND EXISTS(SELECT 1 FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=po.id AND (l.order_unit_quantity_base_snapshot IS NULL OR l.tax_rate_snapshot IS NULL))
     AND(NULLIF(p_query->>'legacy_before','') IS NULL OR(po.created_at,po.id)<((p_query->>'legacy_before')::timestamptz,(p_query->>'legacy_before_id')::uuid)) ORDER BY po.created_at DESC,po.id DESC LIMIT 21),
   lines AS(SELECT l.purchase_order_id,jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name,'current_base_unit',p.base_unit) ORDER BY l.id) rows
     FROM public.inventory_purchase_order_lines l JOIN(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 20) po ON po.id=l.purchase_order_id JOIN public.inventory_products p ON p.id=l.product_id GROUP BY l.purchase_order_id)
   SELECT result||jsonb_build_object('legacy_has_more',(SELECT count(*)>20 FROM page),'legacy_terms_review',COALESCE(jsonb_agg(to_jsonb(po)||jsonb_build_object('lines',COALESCE(l.rows,'[]')) ORDER BY po.created_at DESC,po.id DESC),'[]')) INTO result
     FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 20) po LEFT JOIN lines l ON l.purchase_order_id=po.id;
 END IF;
 IF COALESCE((p_query->>'include_evidence')::boolean,false) THEN result:=result||public.procurement_supplier_evidence(p_store_id,p_office_actor)||jsonb_build_object('demand',public.procurement_demand_evidence(p_store_id,p_office_actor)); END IF;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.procurement_document_data(p_store_id uuid,p_kind text,p_record_id uuid,p_audience text,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; po public.inventory_purchase_orders%rowtype; req public.inventory_purchase_requests%rowtype; result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF p_kind NOT IN ('pr','po') OR p_audience NOT IN ('internal','supplier') OR (p_kind='pr' AND p_audience<>'internal') THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_AUDIENCE_INVALID'; END IF;
 IF p_kind='po' THEN
   SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id AND workflow_version=2;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   IF p_audience='internal' AND NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRICES_FORBIDDEN'; END IF;
   IF p_audience='supplier' THEN
     result:=jsonb_build_object('purchase_order_no',po.purchase_order_no,'commercial_revision',po.commercial_revision,
       'issued_at',po.commercial_terms->'issued_at','requested_delivery_date',po.requested_delivery_date,
       'pr_no',po.commercial_terms->'pr_no','pr_created_at',po.commercial_terms->'pr_created_at','pr_submitted_at',po.commercial_terms->'pr_submitted_at',
       'supplier_name',po.approval_snapshot->'supplier'->'supplier_name','store_name',po.approval_snapshot->'store'->'name',
       'delivery_address',po.commercial_terms->'delivery_address','contact_name',po.commercial_terms->'contact_name',
       'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('product_name',l->'product_name','specification',l->'specification',
         'quantity',l->'ordered_quantity_unit','unit',l->'order_unit','memo',l->'memo') ORDER BY l->>'id')
         FROM jsonb_array_elements(po.approval_snapshot->'lines') l),'[]'));
   ELSE result:=to_jsonb(po); END IF;
   RETURN jsonb_build_object('kind','po','audience',p_audience,'source_hash',po.approval_snapshot_hash,'data',result);
 ELSE
   SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   result:=to_jsonb(req)-'approval_hash'-'brand_approval_hash';
   IF NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN result:=result-'approved_amount'; END IF;
   result:=result||jsonb_build_object('store_name',(SELECT name FROM public.restaurants WHERE id=p_store_id),
     'lines',COALESCE((SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('estimated_amount',round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price,2),'product_name',COALESCE(l.product_name_snapshot,p.name)) ORDER BY l.id)
     FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.request_id=req.id AND l.active),'[]'));
   result:=result||(SELECT jsonb_build_object('estimates_complete',COALESCE(bool_and(l.estimated_unit_price IS NOT NULL AND l.estimated_conversion>0),false),
     'estimated_net',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price,2)),
     'estimated_vat',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price*l.estimated_tax_rate/100,2)),
     'estimated_total',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price,2)+round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price*l.estimated_tax_rate/100,2)))
     FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active);
   RETURN jsonb_build_object('kind','pr','audience','internal','source_hash',encode(extensions.digest(convert_to(result::text,'UTF8'),'sha256'),'hex'),'data',result);
 END IF;
END $$;

-- ACLs survive CREATE OR REPLACE; the internal core functions remain inaccessible to clients.
REVOKE ALL ON FUNCTION public.procurement_workspace_page_core(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
COMMIT;
