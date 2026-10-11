-- POS buyer information only. No MISA dispatch, issuance or payment changes.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

ALTER TABLE public.red_invoice_intakes
 ADD COLUMN buyer_number_type text NOT NULL DEFAULT 'vn_tax' CHECK(buyer_number_type IN ('vn_tax','household_id','personal_id','foreign_tax','passport')),
 ADD COLUMN buyer_number_value text NOT NULL DEFAULT '',
 ADD COLUMN buyer_version bigint NOT NULL DEFAULT 1;
-- Keep legacy invalid numbers verbatim. Display their error; do not repair them.
UPDATE public.red_invoice_intakes SET buyer_number_type=CASE WHEN COALESCE(buyer_tax_code,'')='' AND COALESCE(buyer_id,'')<>'' THEN 'personal_id' ELSE 'vn_tax' END,
 buyer_number_value=COALESCE(NULLIF(buyer_tax_code,''),buyer_id,'');

CREATE FUNCTION public.pos_buyer_number_issue(p_type text,p_value text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE v text:=btrim(COALESCE($2,''));parts text[];
BEGIN
 IF $1 IS NULL OR $1 NOT IN ('vn_tax','household_id','personal_id','foreign_tax','passport') THEN RETURN jsonb_build_object('code','type'); END IF;
 IF v='' THEN RETURN jsonb_build_object('code','required'); END IF;
 IF $1 IN ('foreign_tax','passport') THEN RETURN CASE WHEN char_length(v)>64 THEN jsonb_build_object('code','too_long') ELSE NULL END; END IF;
 IF $1<>'vn_tax' THEN
  IF v!~'^[0-9]+$' THEN RETURN jsonb_build_object('code','digits'); END IF;
  RETURN CASE WHEN char_length(v)=12 THEN NULL ELSE jsonb_build_object('code','identity_length','actual',char_length(v)) END;
 END IF;
 IF v!~'^[0-9-]+$' THEN RETURN jsonb_build_object('code','tax_characters'); END IF;
 IF strpos(v,'-')>0 THEN
  parts:=string_to_array(v,'-');
  IF cardinality(parts)<>2 THEN RETURN jsonb_build_object('code','hyphen'); END IF;
  IF char_length(parts[1])<>10 OR char_length(parts[2])<>3 THEN RETURN jsonb_build_object('code','branch_length','left',char_length(parts[1]),'right',char_length(parts[2])); END IF;
  RETURN CASE WHEN parts[2]='000' THEN jsonb_build_object('code','branch_zero') ELSE NULL END;
 END IF;
 RETURN CASE WHEN char_length(v)=10 THEN NULL ELSE jsonb_build_object('code','tax_length','actual',char_length(v)) END;
END; $$;
REVOKE ALL ON FUNCTION public.pos_buyer_number_issue(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_buyer_number_issue(text,text) TO authenticated,service_role;

CREATE FUNCTION public.pos_buyer_intake_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE issue jsonb;explicit_edit boolean:=current_setting('globos.pos_buyer_explicit',true)='true';changed boolean;
BEGIN
 IF TG_OP='UPDATE' THEN
  -- Legacy minimal/batch writers omitted these fields by passing NULL.
  -- An explicit POS patch can still clear a field intentionally.
  IF NOT COALESCE(explicit_edit,false) THEN
   NEW.buyer_unit_code:=COALESCE(NEW.buyer_unit_code,OLD.buyer_unit_code);
   NEW.buyer_full_name:=COALESCE(NEW.buyer_full_name,OLD.buyer_full_name);
   NEW.buyer_email_cc:=COALESCE(NEW.buyer_email_cc,OLD.buyer_email_cc);
   NEW.buyer_id:=COALESCE(NEW.buyer_id,OLD.buyer_id);
   IF NEW.buyer_number_value=OLD.buyer_number_value AND
    ROW(NEW.buyer_tax_code,NEW.buyer_id) IS DISTINCT FROM ROW(OLD.buyer_tax_code,OLD.buyer_id) THEN
    NEW.buyer_number_value:=COALESCE(CASE WHEN NEW.buyer_number_type IN ('personal_id','passport') THEN NEW.buyer_id ELSE NEW.buyer_tax_code END,'');
   END IF;
  END IF;
 ELSE
  IF NEW.buyer_number_value='' THEN NEW.buyer_number_value:=COALESCE(CASE WHEN NEW.buyer_number_type IN ('personal_id','passport') THEN NEW.buyer_id ELSE NEW.buyer_tax_code END,''); END IF;
 END IF;
 changed:=TG_OP='INSERT';
 IF TG_OP='UPDATE' THEN
  changed:=ROW(NEW.buyer_number_type,NEW.buyer_number_value,NEW.buyer_tax_code,NEW.buyer_unit_code,NEW.buyer_legal_name,NEW.buyer_full_name,
   NEW.buyer_address,NEW.buyer_email,NEW.buyer_email_cc,NEW.buyer_phone,NEW.buyer_id,NEW.source_note,NEW.attachment_urls)
  IS DISTINCT FROM ROW(OLD.buyer_number_type,OLD.buyer_number_value,OLD.buyer_tax_code,OLD.buyer_unit_code,OLD.buyer_legal_name,OLD.buyer_full_name,
   OLD.buyer_address,OLD.buyer_email,OLD.buyer_email_cc,OLD.buyer_phone,OLD.buyer_id,OLD.source_note,OLD.attachment_urls);
  IF changed THEN NEW.buyer_version:=OLD.buyer_version+1; END IF;
 END IF;
 IF NEW.status IN ('ready','exported','completed') AND (TG_OP='INSERT' OR TG_OP='UPDATE' AND (OLD.status='awaiting_information' OR ROW(NEW.buyer_number_type,NEW.buyer_number_value,NEW.buyer_tax_code,NEW.buyer_id,NEW.buyer_legal_name,NEW.buyer_full_name,NEW.buyer_address,NEW.buyer_email,NEW.buyer_phone) IS DISTINCT FROM ROW(OLD.buyer_number_type,OLD.buyer_number_value,OLD.buyer_tax_code,OLD.buyer_id,OLD.buyer_legal_name,OLD.buyer_full_name,OLD.buyer_address,OLD.buyer_email,OLD.buyer_phone))) THEN
  issue:=public.pos_buyer_number_issue(NEW.buyer_number_type,NEW.buyer_number_value);
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.pos_buyer_intake_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pos_buyer_intake_guard BEFORE INSERT OR UPDATE ON public.red_invoice_intakes
 FOR EACH ROW EXECUTE FUNCTION public.pos_buyer_intake_guard();

CREATE FUNCTION public.pos_save_buyer_information(p_store_id uuid,p_order_id uuid,p_expected_version bigint,p_patch jsonb,p_confirm boolean DEFAULT true,p_source text DEFAULT NULL,p_intake_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor public.users%ROWTYPE;existing public.red_invoice_intakes%ROWTYPE;v public.red_invoice_intakes%ROWTYPE;
 v_request_id uuid;data jsonb;issue jsonb;kind text;number text;target_ids uuid[];prior_setting text;
BEGIN
 SELECT * INTO actor FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 IF NOT FOUND OR actor.role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin') THEN RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN'; END IF;
 IF NOT public.is_super_admin() AND NOT EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=$1) THEN RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN'; END IF;
 IF $6 IS NOT NULL AND $6 NOT IN ('cashier','business_card','zalo','other') OR $7 IS NOT NULL AND $7 NOT IN ('awaiting_information','ready','manual_review','cancelled') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF $4 IS NULL OR jsonb_typeof($4)<>'object' OR EXISTS(SELECT 1 FROM jsonb_each($4) e WHERE e.key NOT IN
 ('buyer_number_type','buyer_number_value','buyer_legal_name','buyer_full_name','buyer_address','buyer_email','buyer_email_cc','buyer_phone','buyer_unit_code','buyer_id','source_note')
 OR jsonb_typeof(e.value)<>'string') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 -- Request first, then its intake rows: same lock order as direct-order sync.
 SELECT f.request_id INTO v_request_id FROM public.direct_order_financials f WHERE f.order_id=$2 AND f.restaurant_id=$1;
 IF v_request_id IS NULL THEN SELECT c.request_id INTO v_request_id FROM public.direct_order_payment_charges c WHERE c.order_id=$2 AND c.restaurant_id=$1; END IF;
 IF v_request_id IS NOT NULL THEN PERFORM 1 FROM public.direct_order_requests WHERE id=v_request_id FOR UPDATE; END IF;
 PERFORM 1 FROM public.orders WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
 SELECT * INTO existing FROM public.red_invoice_intakes WHERE order_id=$2 AND store_id=$1 FOR UPDATE;
 IF FOUND AND existing.buyer_version IS DISTINCT FROM $3 OR NOT FOUND AND $3 IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET'; END IF;
 data:=COALESCE(to_jsonb(existing),'{}'::jsonb)||$4;
 kind:=COALESCE(data->>'buyer_number_type','vn_tax');number:=COALESCE(data->>'buyer_number_value','');
 IF kind NOT IN ('vn_tax','household_id','personal_id','foreign_tax','passport') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF $5 OR $7='ready' OR existing.status IN ('ready','exported','completed') THEN
  issue:=public.pos_buyer_number_issue(kind,number);
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
  IF COALESCE(btrim(data->>'buyer_address'),'')='' OR COALESCE(btrim(data->>'buyer_phone'),'')='' OR COALESCE(data->>'buyer_email','') NOT LIKE '%@%'
  OR COALESCE(btrim(CASE WHEN kind IN ('personal_id','passport') THEN data->>'buyer_full_name' ELSE data->>'buyer_legal_name' END),'')=''
  THEN RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE'; END IF;
 END IF;
 IF ($5 OR $7='ready' OR existing.status IN ('ready','exported','completed')) AND kind IN ('vn_tax','household_id') AND COALESCE(data->>'buyer_id','')<>'' THEN
  issue:=public.pos_buyer_number_issue('personal_id',data->>'buyer_id');
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 END IF;
 IF char_length(COALESCE(data->>'buyer_id',''))>64 OR char_length(number)>64 OR char_length(COALESCE(data->>'buyer_address',''))>500 OR char_length(COALESCE(data->>'buyer_legal_name',''))>300
 OR char_length(COALESCE(data->>'buyer_full_name',''))>300 OR char_length(COALESCE(data->>'buyer_email',''))>254
 OR char_length(COALESCE(data->>'buyer_email_cc',''))>1000 OR char_length(COALESCE(data->>'buyer_phone',''))>30
 OR char_length(COALESCE(data->>'source_note',''))>500 OR char_length(COALESCE(data->>'buyer_unit_code',''))>100 THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 prior_setting:=current_setting('globos.pos_buyer_explicit',true);PERFORM set_config('globos.pos_buyer_explicit','true',true);
 IF existing.id IS NULL THEN
  INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,receipt_ids,sale_at,gross_amount,payment_method,line_items_snapshot,status,
   buyer_number_type,buyer_number_value,buyer_tax_code,buyer_id,requested_by,updated_by)
  SELECT $2,$1,r.tax_entity_id,p.ids,p.sale_at,p.gross,p.method,COALESCE(items.lines,'[]'::jsonb),CASE WHEN $5 THEN 'ready' ELSE 'awaiting_information' END,
   kind,number,CASE WHEN kind NOT IN ('personal_id','passport') THEN number END,CASE WHEN kind IN ('personal_id','passport') THEN number END,actor.id,actor.id
  FROM public.restaurants r CROSS JOIN(SELECT array_agg(id::text ORDER BY created_at,id) ids,min(created_at) sale_at,sum(COALESCE(amount_portion,amount)) gross,
   string_agg(DISTINCT method,', ' ORDER BY method) method FROM public.payments WHERE order_id=$2 AND restaurant_id=$1 AND is_revenue) p
  CROSS JOIN(SELECT jsonb_agg(jsonb_build_object('order_item_id',id,'display_name',COALESCE(NULLIF(display_name,''),label,'Item'),
   'quantity',quantity,'unit_price',unit_price,'vat_rate',vat_rate,'vat_amount',vat_amount,'total_amount_ex_tax',total_amount_ex_tax,
   'paying_amount_inc_tax',paying_amount_inc_tax) ORDER BY created_at,id) lines FROM public.order_items WHERE order_id=$2 AND status<>'cancelled') items
  WHERE r.id=$1 AND p.sale_at IS NOT NULL RETURNING * INTO existing;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAID_RECEIPT_REQUIRED'; END IF;
 END IF;
 target_ids:=ARRAY[$2];
 IF v_request_id IS NOT NULL THEN
  SELECT array_agg(order_id) INTO target_ids FROM(SELECT order_id FROM public.direct_order_financials WHERE request_id=v_request_id
   UNION SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=v_request_id AND order_id IS NOT NULL) s;
  PERFORM id FROM public.red_invoice_intakes WHERE order_id=ANY(target_ids) ORDER BY order_id FOR UPDATE;
  UPDATE public.direct_order_requests SET invoice_details=invoice_details||jsonb_build_object('requested',true,'pos_only',true,'buyer_confirmed',$5,'number_type',kind,'number_value',number,
   'tax_code',CASE WHEN kind IN ('personal_id','passport') THEN '' ELSE number END,'legal_name',COALESCE(data->>'buyer_legal_name',''),
   'full_name',COALESCE(data->>'buyer_full_name',''),'address',COALESCE(data->>'buyer_address',''),'email',COALESCE(data->>'buyer_email',''),
   'email_cc',COALESCE(data->>'buyer_email_cc',''),'phone',COALESCE(data->>'buyer_phone',''),'unit_code',COALESCE(data->>'buyer_unit_code',''),
   'buyer_id',CASE WHEN kind IN ('personal_id','passport') THEN number ELSE COALESCE(data->>'buyer_id','') END,'source_note',COALESCE(data->>'source_note','')),
   support_version=support_version+1 WHERE id=v_request_id;
 END IF;
 UPDATE public.red_invoice_intakes SET buyer_number_type=kind,buyer_number_value=number,
  buyer_tax_code=CASE WHEN kind NOT IN ('personal_id','passport') THEN number END,
  buyer_id=CASE WHEN kind IN ('personal_id','passport') THEN number ELSE NULLIF(data->>'buyer_id','') END,
  buyer_legal_name=NULLIF(data->>'buyer_legal_name',''),buyer_full_name=NULLIF(data->>'buyer_full_name',''),buyer_address=NULLIF(data->>'buyer_address',''),
  buyer_email=NULLIF(data->>'buyer_email',''),buyer_email_cc=NULLIF(data->>'buyer_email_cc',''),buyer_phone=NULLIF(data->>'buyer_phone',''),
  buyer_unit_code=NULLIF(data->>'buyer_unit_code',''),source_note=NULLIF(data->>'source_note',''),updated_at=clock_timestamp(),updated_by=actor.id,
  source=COALESCE($6,source),status=CASE WHEN status IN ('exported','completed') THEN status ELSE COALESCE($7,CASE WHEN $5 AND status='awaiting_information' THEN 'ready' ELSE status END) END,
  ready_at=CASE WHEN $5 OR $7='ready' THEN COALESCE(ready_at,now()) ELSE ready_at END
 WHERE store_id=$1 AND order_id=ANY(target_ids);
 PERFORM set_config('globos.pos_buyer_explicit',COALESCE(prior_setting,''),true);
 SELECT * INTO v FROM public.red_invoice_intakes WHERE id=existing.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'pos_buyer_information_update','red_invoice_intakes',v.id,
  jsonb_build_object('order_id',$2,'store_id',$1,'previous_version',existing.buyer_version,'version',v.buyer_version,'changed_fields',ARRAY(SELECT jsonb_object_keys($4))));
 RETURN to_jsonb(v)||jsonb_build_object('store_name',(SELECT name FROM public.restaurants WHERE id=$1),
 'related_buyer_versions',(SELECT COALESCE(jsonb_object_agg(order_id::text,jsonb_build_object('version',buyer_version,'status',status)),'{}'::jsonb) FROM public.red_invoice_intakes WHERE store_id=$1 AND order_id=ANY(target_ids)));
END; $$;
REVOKE ALL ON FUNCTION public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text) TO authenticated,service_role;


CREATE FUNCTION public.pos_sync_direct_buyer_information(p_store_id uuid,p_request_id uuid,p_order_ids uuid[] DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;ids uuid[];actor_id uuid;kind text;number text;complete boolean;prior text;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT invoice_details INTO b FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF b->>'requested' IS DISTINCT FROM 'true' THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RETURN; END IF;
 SELECT id INTO actor_id FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 kind:=COALESCE(b->>'number_type','vn_tax');number:=COALESCE(b->>'number_value',b->>'tax_code','');
 complete:=public.pos_buyer_number_issue(kind,number) IS NULL AND COALESCE(b->>'address','')<>'' AND COALESCE(b->>'phone','')<>''
 AND COALESCE(b->>'email','') LIKE '%@%' AND COALESCE(CASE WHEN kind IN ('personal_id','passport') THEN b->>'full_name' ELSE b->>'legal_name' END,'')<>'';
 SELECT array_agg(DISTINCT order_id) INTO ids FROM(SELECT order_id FROM public.direct_order_financials WHERE request_id=$2
 UNION ALL SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=$2 AND order_id IS NOT NULL) s WHERE $3 IS NULL OR order_id=ANY($3);
 IF cardinality(ids) IS NULL THEN RETURN; END IF;
 PERFORM id FROM public.orders WHERE id=ANY(ids) AND restaurant_id=$1 ORDER BY id FOR UPDATE;
 PERFORM id FROM public.red_invoice_intakes WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 prior:=current_setting('globos.pos_buyer_explicit',true);PERFORM set_config('globos.pos_buyer_explicit','true',true);
 WITH paid AS(SELECT p.order_id,array_agg(p.id::text ORDER BY p.created_at,p.id) receipt_ids,min(p.created_at) sale_at,
 sum(COALESCE(p.amount_portion,p.amount)) gross_amount,string_agg(DISTINCT p.method,', ' ORDER BY p.method) method FROM public.payments p
 WHERE p.order_id=ANY(ids) AND p.restaurant_id=$1 AND p.is_revenue GROUP BY p.order_id),
 items AS(SELECT i.order_id,jsonb_agg(jsonb_build_object('order_item_id',i.id,'display_name',COALESCE(NULLIF(i.display_name,''),i.label,'Item'),
 'quantity',i.quantity,'unit_price',i.unit_price,'vat_rate',i.vat_rate,'vat_amount',i.vat_amount,'total_amount_ex_tax',i.total_amount_ex_tax,
 'paying_amount_inc_tax',i.paying_amount_inc_tax) ORDER BY i.created_at,i.id) lines FROM public.order_items i WHERE i.order_id=ANY(ids) AND i.status<>'cancelled' GROUP BY i.order_id)
 INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,receipt_ids,sale_at,gross_amount,payment_method,line_items_snapshot,
 source,status,buyer_number_type,buyer_number_value,buyer_tax_code,buyer_id,buyer_legal_name,buyer_full_name,buyer_address,buyer_email,
 buyer_email_cc,buyer_phone,buyer_unit_code,source_note,requested_by,updated_by,ready_at)
 SELECT paid.order_id,$1,r.tax_entity_id,paid.receipt_ids,paid.sale_at,paid.gross_amount,paid.method,COALESCE(items.lines,'[]'::jsonb),'cashier',
 CASE WHEN complete THEN 'ready' ELSE 'awaiting_information' END,kind,number,
 CASE WHEN kind NOT IN ('personal_id','passport') THEN NULLIF(number,'') END,CASE WHEN kind IN ('personal_id','passport') THEN NULLIF(number,'') ELSE NULLIF(b->>'buyer_id','') END,
 NULLIF(b->>'legal_name',''),NULLIF(b->>'full_name',''),NULLIF(b->>'address',''),NULLIF(b->>'email',''),NULLIF(b->>'email_cc',''),NULLIF(b->>'phone',''),
 NULLIF(b->>'unit_code',''),COALESCE(NULLIF(b->>'source_note',''),'Direct Order'),actor_id,actor_id,CASE WHEN complete THEN now() END
 FROM paid JOIN public.restaurants r ON r.id=$1 LEFT JOIN items ON items.order_id=paid.order_id
 ON CONFLICT(order_id) DO UPDATE SET buyer_number_type=EXCLUDED.buyer_number_type,buyer_number_value=EXCLUDED.buyer_number_value,
 buyer_tax_code=EXCLUDED.buyer_tax_code,buyer_id=CASE WHEN b?'buyer_id' OR kind IN ('personal_id','passport') THEN EXCLUDED.buyer_id ELSE red_invoice_intakes.buyer_id END,
 buyer_legal_name=EXCLUDED.buyer_legal_name,buyer_full_name=CASE WHEN b?'full_name' THEN EXCLUDED.buyer_full_name ELSE red_invoice_intakes.buyer_full_name END,
 buyer_address=EXCLUDED.buyer_address,buyer_email=EXCLUDED.buyer_email,buyer_email_cc=CASE WHEN b?'email_cc' THEN EXCLUDED.buyer_email_cc ELSE red_invoice_intakes.buyer_email_cc END,
 buyer_phone=EXCLUDED.buyer_phone,buyer_unit_code=CASE WHEN b?'unit_code' THEN EXCLUDED.buyer_unit_code ELSE red_invoice_intakes.buyer_unit_code END,
 source_note=CASE WHEN b?'source_note' THEN EXCLUDED.source_note ELSE red_invoice_intakes.source_note END,
 status=CASE WHEN red_invoice_intakes.status='awaiting_information' AND complete THEN 'ready' ELSE red_invoice_intakes.status END,
 ready_at=CASE WHEN complete THEN COALESCE(red_invoice_intakes.ready_at,now()) ELSE red_invoice_intakes.ready_at END,updated_by=actor_id,updated_at=now();
 PERFORM set_config('globos.pos_buyer_explicit',COALESCE(prior,''),true);
END; $$;
REVOKE ALL ON FUNCTION public.pos_sync_direct_buyer_information(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.direct_order_sync_invoice_batch(uuid,uuid,uuid[]) RENAME TO direct_order_sync_invoice_before_pos_buyer;
CREATE FUNCTION public.direct_order_sync_invoice_batch(p_store_id uuid,p_request_id uuid,p_order_ids uuid[] DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT invoice_details INTO b FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF b->>'requested' IS DISTINCT FROM 'true' THEN RETURN; END IF;
 IF b->>'pos_only' IS DISTINCT FROM 'true' AND (COALESCE(b->>'tax_code','')='' OR public.pos_buyer_number_issue('vn_tax',b->>'tax_code') IS NULL) THEN
  PERFORM public.direct_order_sync_invoice_before_pos_buyer($1,$2,$3);
 END IF;
 PERFORM public.pos_sync_direct_buyer_information($1,$2,$3);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_sync_invoice_batch(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.pos_direct_order_save_buyer(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE;kind text;number text;issue jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET'; END IF;
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.support_version IS DISTINCT FROM $3 THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 IF jsonb_typeof($4)<>'object' OR EXISTS(SELECT 1 FROM jsonb_each($4) e WHERE e.key NOT IN
 ('buyer_number_type','buyer_number_value','buyer_legal_name','buyer_full_name','buyer_address','buyer_email','buyer_email_cc','buyer_phone','buyer_unit_code','buyer_id','source_note') OR jsonb_typeof(e.value)<>'string') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 kind:=$4->>'buyer_number_type';number:=$4->>'buyer_number_value';issue:=public.pos_buyer_number_issue(kind,number);
 IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 IF COALESCE($4->>'buyer_address','')='' OR COALESCE($4->>'buyer_phone','')='' OR COALESCE($4->>'buyer_email','') NOT LIKE '%@%'
 OR COALESCE(CASE WHEN kind IN ('personal_id','passport') THEN $4->>'buyer_full_name' ELSE $4->>'buyer_legal_name' END,'')=''
 THEN RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE'; END IF;
 IF kind IN ('vn_tax','household_id') AND COALESCE($4->>'buyer_id','')<>'' AND public.pos_buyer_number_issue('personal_id',$4->>'buyer_id') IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text($4) e WHERE char_length(e.value)>CASE e.key WHEN 'buyer_number_value' THEN 64 WHEN 'buyer_id' THEN 64 WHEN 'buyer_email' THEN 254 WHEN 'buyer_email_cc' THEN 1000 WHEN 'buyer_phone' THEN 30 WHEN 'buyer_legal_name' THEN 300 WHEN 'buyer_full_name' THEN 300 WHEN 'buyer_unit_code' THEN 100 ELSE 500 END) THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 UPDATE public.direct_order_requests SET invoice_details=invoice_details||jsonb_build_object('requested',true,'pos_only',true,'buyer_confirmed',true,'number_type',kind,'number_value',number,
 'tax_code',CASE WHEN kind IN ('personal_id','passport') THEN '' ELSE number END,'legal_name',$4->>'buyer_legal_name','full_name',$4->>'buyer_full_name',
 'address',$4->>'buyer_address','email',$4->>'buyer_email','email_cc',$4->>'buyer_email_cc','phone',$4->>'buyer_phone','unit_code',$4->>'buyer_unit_code',
 'buyer_id',CASE WHEN kind IN ('personal_id','passport') THEN number ELSE $4->>'buyer_id' END,'source_note',$4->>'source_note'),support_version=support_version+1
 WHERE id=$2 RETURNING * INTO r;
 PERFORM public.pos_sync_direct_buyer_information($1,$2);
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'pos_direct_buyer_update','direct_order_requests',$2,jsonb_build_object('version',r.support_version));
 RETURN jsonb_build_object('version',r.support_version,'invoice',r.invoice_details);
END; $$;
REVOKE ALL ON FUNCTION public.pos_direct_order_save_buyer(uuid,uuid,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_direct_order_save_buyer(uuid,uuid,integer,jsonb) TO authenticated,service_role;

-- Compatibility with older five-field clients: merging their partial payload
-- cannot erase the typed POS record or reactivate external invoice mutation.
CREATE FUNCTION public.pos_direct_buyer_source_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE b jsonb;issue jsonb;
BEGIN
 IF OLD.invoice_details->>'pos_only'='true' OR NEW.invoice_details->>'pos_only'='true' THEN
  b:=NEW.invoice_details;
  NEW.invoice_details:=OLD.invoice_details||b;
  IF NOT b?'number_value' AND b?'tax_code' AND b->>'tax_code' IS DISTINCT FROM OLD.invoice_details->>'tax_code' THEN
   NEW.invoice_details:=NEW.invoice_details||jsonb_build_object('number_type','vn_tax','number_value',b->>'tax_code');
  END IF;
  IF NEW.invoice_details->>'requested'='true' AND NEW.invoice_details->>'buyer_confirmed' IS DISTINCT FROM 'false' AND NEW.invoice_details IS DISTINCT FROM OLD.invoice_details THEN
   issue:=public.pos_buyer_number_issue(NEW.invoice_details->>'number_type',NEW.invoice_details->>'number_value');
   IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
  END IF;
 END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.pos_direct_buyer_source_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pos_direct_buyer_source_guard BEFORE UPDATE OF invoice_details ON public.direct_order_requests
 FOR EACH ROW EXECUTE FUNCTION public.pos_direct_buyer_source_guard();

DO $verify$
BEGIN
 IF has_function_privilege('anon','public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text)','EXECUTE')
 OR public.pos_buyer_number_issue('vn_tax','0312345678-001') IS NOT NULL
 OR public.pos_buyer_number_issue('vn_tax','0312345678-000') IS NULL
 OR public.pos_buyer_number_issue('household_id','001234567890') IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_POLICY_DRIFT'; END IF;
END; $verify$;
COMMIT;
