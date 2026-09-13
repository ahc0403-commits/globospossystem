-- Shared procurement v2. Activation is explicit per store; existing orders remain v1.
BEGIN;
ALTER TABLE public.inventory_purchase_orders
 ADD COLUMN workflow_version integer NOT NULL DEFAULT 1 CHECK (workflow_version IN (1,2)),
 ADD COLUMN procurement_status text,
 ADD COLUMN commercial_revision integer NOT NULL DEFAULT 1,
 ADD COLUMN commercial_terms jsonb NOT NULL DEFAULT '{}';

CREATE TABLE public.procurement_store_policies (
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id),
 enabled boolean NOT NULL DEFAULT false,
 high_value_amount numeric(14,2) CHECK (high_value_amount>0 AND high_value_amount::text<>'NaN'),
 max_price_increase_percent numeric(7,2) CHECK (max_price_increase_percent>=0 AND max_price_increase_percent::text<>'NaN'),
 quantity_review_multiplier numeric(7,2) CHECK(quantity_review_multiplier>=1 AND quantity_review_multiplier::text<>'NaN'),
 stock_freshness_hours integer NOT NULL DEFAULT 24 CHECK (stock_freshness_hours BETWEEN 1 AND 720),
 row_version integer NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.inventory_purchase_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_no text NOT NULL UNIQUE DEFAULT ('PR-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 source text NOT NULL CHECK (source IN ('pos','office','scheduled')),
 status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','office_review','senior_review','approved','allocated','returned','cancelled')),
 requested_delivery_date date NOT NULL,
 reason text NOT NULL CHECK (length(btrim(reason))>0),
 memo text,
 created_actor jsonb NOT NULL,
 store_approved_actor jsonb,
 office_approved_actor jsonb,
 senior_approved_actor jsonb,
 approved_amount numeric(14,2),
 approval_hash text,
 row_version integer NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX procurement_requests_store_updated ON public.inventory_purchase_requests(restaurant_id,updated_at DESC);
CREATE TABLE public.inventory_purchase_request_lines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_id uuid NOT NULL REFERENCES public.inventory_purchase_requests(id),
 product_id uuid NOT NULL REFERENCES public.inventory_products(id),
 requested_quantity numeric(12,3) NOT NULL CHECK (requested_quantity>0),
 requested_unit text NOT NULL,
 quantity_base numeric(12,3) NOT NULL CHECK (quantity_base>0),
 conversion_snapshot numeric(12,3) NOT NULL CHECK (conversion_snapshot>0),
 current_stock_snapshot numeric,
 stock_updated_at timestamptz,
 preferred_supplier_id uuid REFERENCES public.inventory_suppliers(id),
 memo text,
 active boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX procurement_active_request_product ON public.inventory_purchase_request_lines(request_id,product_id) WHERE active;
CREATE TABLE public.procurement_quotes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_id uuid NOT NULL REFERENCES public.inventory_purchase_requests(id),
 supplier_id uuid NOT NULL REFERENCES public.inventory_suppliers(id),
 valid_until date NOT NULL,
 delivery_date date NOT NULL,
 payment_terms text NOT NULL,
 evidence_reference text NOT NULL,
 selection_reason text,
 selected boolean NOT NULL DEFAULT false,
 archived boolean NOT NULL DEFAULT false,
 row_version integer NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.procurement_quote_lines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 quote_id uuid NOT NULL REFERENCES public.procurement_quotes(id),
 request_line_id uuid NOT NULL REFERENCES public.inventory_purchase_request_lines(id),
 supplier_item_id uuid NOT NULL REFERENCES public.inventory_supplier_items(id),
 quantity_base numeric(12,3) NOT NULL CHECK (quantity_base>0),
 order_unit text NOT NULL,
 conversion_snapshot numeric(12,3) NOT NULL CHECK (conversion_snapshot>0),
 unit_price numeric(12,2) NOT NULL CHECK (unit_price>0 AND unit_price::text<>'NaN'),
 tax_rate numeric(5,2) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100),
 reference_unit_price numeric(12,2) NOT NULL,
 UNIQUE(quote_id,request_line_id)
);
CREATE TABLE public.procurement_allocations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_line_id uuid NOT NULL REFERENCES public.inventory_purchase_request_lines(id),
 quote_line_id uuid NOT NULL UNIQUE REFERENCES public.procurement_quote_lines(id),
 purchase_order_line_id uuid NOT NULL UNIQUE REFERENCES public.inventory_purchase_order_lines(id),
 quantity_base numeric(12,3) NOT NULL CHECK (quantity_base>0),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.procurement_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 record_id uuid NOT NULL,
 action text NOT NULL,
 actor jsonb NOT NULL,
 previous_state jsonb,
 next_state jsonb,
 reason text,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX procurement_events_record ON public.procurement_events(record_id,created_at);
CREATE TABLE public.procurement_command_results (
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 idempotency_key text NOT NULL,
 actor_key text NOT NULL,
 payload_hash text NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(restaurant_id,idempotency_key)
);

-- Only typed SECURITY DEFINER RPCs mutate these records.
DO $acl$
DECLARE n text;
BEGIN
 FOREACH n IN ARRAY ARRAY['procurement_store_policies','inventory_purchase_requests','inventory_purchase_request_lines',
 'procurement_quotes','procurement_quote_lines','procurement_allocations','procurement_events','procurement_command_results'] LOOP
   EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n);
   EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',n);
   EXECUTE format('GRANT ALL ON TABLE public.%I TO service_role',n);
 END LOOP;
END $acl$;

CREATE FUNCTION public.procurement_actor(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
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
 RETURN jsonb_build_object('system','pos','subject_id',auth.uid(),'store_id',p_store_id,'role',role_name,
 'can_create',role_name IN ('inventory_orderer','admin','store_admin','brand_admin','super_admin'),
 'can_store_approve',role_name IN ('admin','store_admin','brand_admin','super_admin'),
 'can_office_approve',false,'can_senior_approve',false,'can_manage',role_name='super_admin',
 'can_view_prices',role_name<>'inventory_orderer');
END $$;
REVOKE ALL ON FUNCTION public.procurement_actor(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.procurement_request_hash(p_request_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 SELECT encode(extensions.digest(convert_to(jsonb_build_object(
 'request',jsonb_build_object('id',r.id,'store',r.restaurant_id,'date',r.requested_delivery_date,'reason',r.reason),
 'lines',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.inventory_purchase_request_lines l WHERE l.request_id=r.id AND l.active),
 'quotes',(SELECT jsonb_agg(to_jsonb(q)||jsonb_build_object('lines',(
   SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.procurement_quote_lines l WHERE l.quote_id=q.id
 )) ORDER BY q.id) FROM public.procurement_quotes q WHERE q.request_id=r.id AND q.selected)
 )::text,'UTF8'),'sha256'),'hex') FROM public.inventory_purchase_requests r WHERE r.id=p_request_id
$$;
REVOKE ALL ON FUNCTION public.procurement_request_hash(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.procurement_command(
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
 SELECT * INTO policy FROM public.procurement_store_policies WHERE restaurant_id=p_store_id FOR UPDATE;
 IF p_action='configure' THEN
   IF COALESCE((actor->>'can_manage')::boolean,false)=false THEN RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN'; END IF;
   IF policy.restaurant_id IS NOT NULL AND policy.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
   old_state:=to_jsonb(policy);
   INSERT INTO public.procurement_store_policies(restaurant_id,enabled,high_value_amount,max_price_increase_percent,stock_freshness_hours,quantity_review_multiplier)
   VALUES(p_store_id,COALESCE((p_payload->>'enabled')::boolean,false),(p_payload->>'high_value_amount')::numeric,
   (p_payload->>'max_price_increase_percent')::numeric,COALESCE((p_payload->>'stock_freshness_hours')::integer,24),(p_payload->>'quantity_review_multiplier')::numeric)
   ON CONFLICT(restaurant_id) DO UPDATE SET enabled=EXCLUDED.enabled,high_value_amount=EXCLUDED.high_value_amount,
     max_price_increase_percent=EXCLUDED.max_price_increase_percent,stock_freshness_hours=EXCLUDED.stock_freshness_hours,
     quantity_review_multiplier=EXCLUDED.quantity_review_multiplier,
     row_version=procurement_store_policies.row_version+1,updated_at=now() RETURNING * INTO policy;
   result:=to_jsonb(policy)||jsonb_build_object('id',p_store_id);
 ELSE
   IF NOT COALESCE(policy.enabled,false) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_ENABLED'; END IF;
   IF p_action IN ('create_request','save_request') THEN
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
         office_approved_actor=NULL,senior_approved_actor=NULL,approval_hash=NULL WHERE id=req.id RETURNING * INTO req;
     ELSE
       INSERT INTO public.inventory_purchase_requests(restaurant_id,source,requested_delivery_date,reason,memo,created_actor)
       VALUES(p_store_id,actor->>'system',(p_payload->>'requested_delivery_date')::date,command_reason,p_payload->>'memo',actor) RETURNING * INTO req;
     END IF;
     IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines') NOT BETWEEN 1 AND 200 THEN
       RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
     FOR item IN SELECT * FROM jsonb_array_elements(p_payload->'lines') LOOP
       SELECT * INTO product FROM public.inventory_products WHERE id=(item->>'product_id')::uuid AND restaurant_id=p_store_id AND is_active AND is_orderable;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
       v_quantity:=(item->>'quantity')::numeric;
       IF v_quantity IS NULL OR v_quantity<=0 OR v_quantity<>round(v_quantity,3) OR v_quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
       conversion:=CASE WHEN item->>'unit'=product.base_unit THEN 1 WHEN item->>'unit'=product.stock_unit THEN product.base_unit_factor END;
       IF conversion IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_UNIT_INVALID'; END IF;
       IF NULLIF(item->>'preferred_supplier_id','') IS NOT NULL AND NOT EXISTS(
         SELECT 1 FROM public.inventory_supplier_items si JOIN public.inventory_suppliers su ON su.id=si.supplier_id
         WHERE si.supplier_id=(item->>'preferred_supplier_id')::uuid AND si.product_id=product.id AND si.is_active AND su.status='active') THEN
         RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_INVALID'; END IF;
       INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot,
         current_stock_snapshot,stock_updated_at,preferred_supplier_id,memo)
       SELECT req.id,product.id,v_quantity,item->>'unit',v_quantity*conversion,conversion,it.current_stock,it.updated_at,
         NULLIF(item->>'preferred_supplier_id','')::uuid,item->>'memo' FROM (SELECT 1) singleton
         LEFT JOIN public.inventory_items it ON it.id=product.inventory_item_id AND it.restaurant_id=p_store_id;
     END LOOP;
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
       UPDATE public.inventory_purchase_requests SET status='submitted' WHERE id=req.id;
     WHEN 'store_approve' THEN
       IF NOT COALESCE((actor->>'can_store_approve')::boolean,false) OR req.status<>'submitted' THEN RAISE EXCEPTION 'PROCUREMENT_STORE_APPROVAL_FORBIDDEN'; END IF;
       UPDATE public.inventory_purchase_requests SET status='office_review',store_approved_actor=actor WHERE id=req.id;
     WHEN 'return_request' THEN
       IF command_reason IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_REQUIRED'; END IF;
       IF NOT ((req.status='submitted' AND COALESCE((actor->>'can_store_approve')::boolean,false))
         OR (req.status IN ('office_review','senior_review') AND COALESCE((actor->>'can_office_approve')::boolean,false))) THEN
         RAISE EXCEPTION 'PROCUREMENT_RETURN_FORBIDDEN'; END IF;
       UPDATE public.inventory_purchase_requests SET status='returned',approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
     WHEN 'save_quote' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status NOT IN ('office_review','senior_review','approved') THEN
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
       FOR item IN SELECT * FROM jsonb_array_elements(p_payload->'lines') LOOP
         SELECT * INTO line FROM public.inventory_purchase_request_lines WHERE id=(item->>'request_line_id')::uuid AND request_id=req.id AND active;
         IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_LINE_INVALID'; END IF;
         SELECT * INTO supplier_item FROM public.inventory_supplier_items WHERE id=(item->>'supplier_item_id')::uuid
           AND supplier_id=quote.supplier_id AND product_id=line.product_id AND is_active;
         IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_ITEM_INVALID'; END IF;
         v_quantity:=(item->>'quantity_base')::numeric;
         IF v_quantity IS NULL OR v_quantity<=0 OR v_quantity>line.quantity_base OR v_quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
         IF round(v_quantity/supplier_item.order_unit_quantity_base,3)*supplier_item.order_unit_quantity_base<>v_quantity THEN
           RAISE EXCEPTION 'PROCUREMENT_ORDER_PRECISION_INVALID'; END IF;
         IF v_quantity/supplier_item.order_unit_quantity_base<supplier_item.min_order_quantity THEN
           RAISE EXCEPTION 'PROCUREMENT_MOQ_REQUIRED'; END IF;
         INSERT INTO public.procurement_quote_lines(quote_id,request_line_id,supplier_item_id,quantity_base,order_unit,conversion_snapshot,unit_price,tax_rate,reference_unit_price)
         VALUES(quote.id,line.id,supplier_item.id,v_quantity,supplier_item.order_unit,supplier_item.order_unit_quantity_base,
           (item->>'unit_price')::numeric,(item->>'tax_rate')::numeric,supplier_item.unit_price);
       END LOOP;
       UPDATE public.inventory_purchase_requests SET status='office_review',approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
     WHEN 'select_quote' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status NOT IN ('office_review','senior_review','approved') OR command_reason IS NULL THEN
         RAISE EXCEPTION 'PROCUREMENT_SELECTION_FORBIDDEN'; END IF;
       IF EXISTS(SELECT 1 FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE l.request_id=req.id) THEN
         RAISE EXCEPTION 'PROCUREMENT_ALLOCATED_TERMS_IMMUTABLE'; END IF;
       UPDATE public.procurement_quotes SET selected=COALESCE((p_payload->>'selected')::boolean,true),selection_reason=command_reason,row_version=row_version+1
         WHERE id=(p_payload->>'quote_id')::uuid AND request_id=req.id AND NOT archived AND valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date RETURNING * INTO quote;
       IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_QUOTE_INVALID'; END IF;
       IF EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active AND l.quantity_base<(
         SELECT sum(ql.quantity_base) FROM public.procurement_quote_lines ql JOIN public.procurement_quotes q ON q.id=ql.quote_id
         WHERE ql.request_line_id=l.id AND q.selected)) THEN RAISE EXCEPTION 'PROCUREMENT_OVER_ALLOCATION'; END IF;
       UPDATE public.inventory_purchase_requests SET status='office_review',approval_hash=NULL,office_approved_actor=NULL,senior_approved_actor=NULL WHERE id=req.id;
     WHEN 'office_approve' THEN
       IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) OR req.status<>'office_review' THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
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
         approved_amount=total,office_approved_actor=actor,approval_hash=public.procurement_request_hash(req.id) WHERE id=req.id;
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
           'payment_terms',quote.payment_terms,'delivery_address',p_payload->>'delivery_address','contact_name',p_payload->>'contact_name','issued_by',actor,'issued_at',now()),req.approval_hash
       FROM public.restaurants r WHERE r.id=p_store_id RETURNING * INTO po;
       FOR qline IN SELECT * FROM public.procurement_quote_lines WHERE quote_id=quote.id ORDER BY id LOOP
         SELECT * INTO line FROM public.inventory_purchase_request_lines WHERE id=qline.request_line_id FOR UPDATE;
         IF EXISTS(SELECT 1 FROM public.procurement_allocations WHERE quote_line_id=qline.id) OR line.quantity_base<qline.quantity_base+COALESCE((
           SELECT sum(quantity_base) FROM public.procurement_allocations WHERE request_line_id=line.id),0) THEN RAISE EXCEPTION 'PROCUREMENT_OVER_ALLOCATION'; END IF;
         INSERT INTO public.inventory_purchase_order_lines(purchase_order_id,product_id,supplier_item_id,ordered_quantity_base,ordered_quantity_unit,order_unit,
           unit_price,supply_amount,tax_amount,recommendation_snapshot)
         VALUES(po.id,line.product_id,qline.supplier_item_id,qline.quantity_base,qline.quantity_base/qline.conversion_snapshot,qline.order_unit,qline.unit_price,
           round(qline.quantity_base/qline.conversion_snapshot*qline.unit_price,2),round(qline.quantity_base/qline.conversion_snapshot*qline.unit_price*qline.tax_rate/100,2),
           jsonb_build_object('tax_rate',qline.tax_rate,'order_unit_quantity_base',qline.conversion_snapshot,'request_line_id',line.id,'quote_line_id',qline.id)) RETURNING * INTO po_line;
         INSERT INTO public.procurement_allocations(request_line_id,quote_line_id,purchase_order_line_id,quantity_base) VALUES(line.id,qline.id,po_line.id,qline.quantity_base);
       END LOOP;
       PERFORM public.recalculate_inventory_purchase_order_totals(po.id);
       UPDATE public.inventory_purchase_orders SET status='ordered',approval_snapshot_version=1,document_status='pending',
         approval_snapshot=jsonb_build_object('order',(SELECT to_jsonb(x) FROM public.inventory_purchase_orders x WHERE x.id=po.id),
           'supplier',(SELECT to_jsonb(s) FROM public.inventory_suppliers s WHERE s.id=po.supplier_id),
           'store',(SELECT to_jsonb(r) FROM public.restaurants r WHERE r.id=p_store_id),
           'lines',(SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name) ORDER BY l.id)
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
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;
COMMIT;
