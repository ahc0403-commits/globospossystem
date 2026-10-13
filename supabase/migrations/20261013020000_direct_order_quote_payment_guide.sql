-- Quote creation, bounded amount preview, staff order links and payment documents.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

CREATE FUNCTION public.direct_order_quote_preview_core(p_store_id uuid,p_request_id uuid,p_validate_menu boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE mode text; enabled boolean; rate numeric; minimum numeric; result jsonb; n integer;
BEGIN
 SELECT COALESCE(s.vat_pricing_mode,'exclusive'),COALESCE(b.service_charge_enabled,false),COALESCE(b.service_charge_rate,0),sf.minimum_order_amount
 INTO mode,enabled,rate,minimum FROM public.restaurants s LEFT JOIN public.brands b ON b.id=s.brand_id
 JOIN public.direct_order_storefronts sf ON sf.restaurant_id=s.id WHERE s.id=p_store_id AND sf.is_enabled
 AND sf.accounting_approved_at IS NOT NULL AND sf.accounting_approved_by IS NOT NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED'; END IF;
 SELECT count(*) INTO n FROM public.direct_order_request_items WHERE request_id=p_request_id AND restaurant_id=p_store_id;
 IF n NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID'; END IF;
 IF p_validate_menu AND EXISTS(SELECT 1 FROM public.direct_order_request_items i LEFT JOIN public.menu_items m ON m.id=i.menu_item_id
 WHERE i.request_id=p_request_id AND (m.id IS NULL OR m.restaurant_id<>p_store_id OR NOT m.is_available OR NOT m.is_visible_public OR m.price IS DISTINCT FROM i.unit_price))
 THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED'; END IF;
 WITH priced AS MATERIALIZED(
  SELECT i.*,public.calculate_item_vat(COALESCE(NULLIF(to_jsonb(i)->'vat_profile_snapshot','null'::jsonb),
   jsonb_build_array(jsonb_build_object('rate',CASE WHEN i.vat_category='alcohol' THEN 10 ELSE 8 END,'weight',1))),round(i.unit_price*i.quantity,2),mode) tax
  FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
 ), totals AS(SELECT sum((tax->>'supply')::numeric) supply,sum((tax->>'vat')::numeric) vat,sum((tax->>'total')::numeric) total FROM priced),
 parts AS(SELECT (e->>'vat_rate')::numeric vat_rate,sum((e->>'total_amount_ex_tax')::numeric) supply FROM priced CROSS JOIN LATERAL jsonb_array_elements(tax->'parts') e GROUP BY 1),
 service AS(SELECT COALESCE(sum(round(supply*rate/100,2)),0) supply,COALESCE(sum(round(round(supply*rate/100,2)*vat_rate/100,2)),0) vat FROM parts WHERE enabled AND rate>0 AND vat_rate IN(8,10))
 SELECT jsonb_build_object('menu_pretax',t.supply,'menu_vat',t.vat,'menu_total',t.total,
  'service_charge_pretax',s.supply,'service_charge_vat',s.vat,'service_charge_total',s.supply+s.vat,
  'delivery_fee_total',0,'delivery_fee_pretax',0,'delivery_fee_vat',0,'final_total',t.total+s.supply+s.vat,
  'vat_pricing_mode',mode) INTO result FROM totals t CROSS JOIN service s;
 IF (result->>'menu_total')::numeric<minimum THEN RAISE EXCEPTION 'DIRECT_ORDER_BELOW_MINIMUM'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_quote_preview_core(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;

-- Adapt the actual effective writer, including the deployed VAT-aware variant.
-- No historical quotes or validation triggers are changed. Preview and writes
-- share the same bounded calculation, so a preview cannot become a client total.
DO $writer$
DECLARE d text; a integer; b integer; block text; replacement text; pickup_mode text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_quote_before_final_amount(uuid,uuid,numeric,text)'::regprocedure) INTO d;
 a:=strpos(d,'  SELECT COALESCE(store.vat_pricing_mode'); b:=strpos(d,'  IF v_storefront.delivery_fee_vat_rate = 0 THEN');
 IF a=0 OR b<=a THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_WRITER_ANCHOR_DRIFT'; END IF;
 d:=substr(d,1,a-1)||$calc$  v_tax:=public.direct_order_quote_preview_core(p_store_id,v_request.id);
  v_menu_pretax:=(v_tax->>'menu_pretax')::numeric;
  v_menu_vat:=(v_tax->>'menu_vat')::numeric;
  v_menu_total:=(v_tax->>'menu_total')::numeric;
  v_sc_pretax:=(v_tax->>'service_charge_pretax')::numeric;
  v_sc_vat:=(v_tax->>'service_charge_vat')::numeric;
  v_sc_total:=(v_tax->>'service_charge_total')::numeric;
$calc$||substr(d,b);
 IF strpos(d,'  v_tax jsonb;')=0 THEN d:=replace(d,E'DECLARE\n',E'DECLARE\n  v_tax jsonb;\n'); END IF;
 SELECT CASE WHEN EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.direct_order_quotes'::regclass
 AND pg_get_constraintdef(oid) LIKE '%not_applicable%') THEN 'not_applicable' ELSE 'customer_direct' END INTO pickup_mode;
 a:=strpos(d,'  INSERT INTO public.direct_order_quotes('); b:=strpos(substr(d,a),') RETURNING * INTO v_quote;');
 IF a=0 OR b=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INSERT_ANCHOR_DRIFT'; END IF;
 block:=substr(d,a,b+length(') RETURNING * INTO v_quote;')-1);
 replacement:=substr(block,1,strpos(block,'  ) VALUES ('));
 IF strpos(replacement,'delivery_payment_mode')=0 THEN block:=replace(block,'created_by, expires_at','created_by, expires_at, delivery_payment_mode'); END IF;
 block:=regexp_replace(block,'now\(\) \+ make_interval\(mins => v_storefront.quote_ttl_minutes\)[\s\S]*\) RETURNING \* INTO v_quote;',
 'now() + make_interval(mins => v_storefront.quote_ttl_minutes), CASE WHEN to_jsonb(v_request)->>''fulfillment_type''=''pickup'' THEN '''||pickup_mode||''' WHEN to_jsonb(v_request)->>''fulfillment_type'' IS NULL AND v_request.fulfillment_method=''pickup'' THEN ''customer_direct'' WHEN v_request.delivery_policy_version=2 THEN ''customer_direct'' ELSE ''store_prepaid'' END'||E'\n  ) RETURNING * INTO v_quote;');
 IF strpos(block,'WHEN v_request.delivery_policy_version=2 THEN ''customer_direct''')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_MODE_PATCH_FAILED'; END IF;
 d:=substr(d,1,a-1)||block||substr(d,a+b+length(') RETURNING * INTO v_quote;')-1);
 EXECUTE d;
END $writer$;

-- Older cashier clients send customer_direct for pickup. Normalize only this
-- representation; delivery requests still reject collection of courier fees.
DO $entry$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)'::regprocedure) INTO d;
 IF EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.direct_order_quotes'::regclass AND pg_get_constraintdef(oid) LIKE '%not_applicable%') THEN
  IF strpos(d,' mode:=COALESCE')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_ENTRY_ANCHOR_DRIFT'; END IF;
  d:=replace(d,' mode:=COALESCE',$patch$ IF r.fulfillment_type='pickup' AND p_delivery_payment_mode='customer_direct' THEN p_delivery_payment_mode:='not_applicable'; END IF;
 mode:=COALESCE$patch$);EXECUTE d;
 END IF;
END $entry$;

CREATE FUNCTION public.direct_order_staff_detail_v7(p_store_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb; q jsonb; summary jsonb; err text;
BEGIN
 b:=public.direct_order_staff_detail_v6($1,$2);
 SELECT to_jsonb(x)-ARRAY['restaurant_id','created_by'] INTO q FROM public.direct_order_quotes x
 WHERE request_id=$2 AND restaurant_id=$1 AND status IN('active','locked') ORDER BY version DESC LIMIT 1;
 IF q IS NOT NULL THEN summary:=jsonb_build_object('finalized',true,'amounts',q);
 ELSIF b->'request'->>'state'='awaiting_quote' THEN
  BEGIN summary:=jsonb_build_object('finalized',false,'amounts',public.direct_order_quote_preview_core($1,$2));
  EXCEPTION WHEN OTHERS THEN err:=CASE WHEN SQLERRM ~ '^DIRECT_ORDER_[A-Z_]+$' THEN SQLERRM ELSE 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE' END;
   summary:=jsonb_build_object('finalized',false,'error_code',err);
  END;
 END IF;
 RETURN b||jsonb_build_object('amount_summary',summary,'can_issue_order_link',public.direct_order_access_is_open($2));
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v7(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v7(uuid,uuid) TO authenticated,service_role;

-- Order access credentials must not enter the translation provider queue.
DO $translation$ DECLARE d text; BEGIN
 IF to_regprocedure('public.direct_order_enqueue_translation()') IS NOT NULL THEN
  SELECT pg_get_functiondef('public.direct_order_enqueue_translation()'::regprocedure) INTO d;
  IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_ANCHOR_DRIFT'; END IF;
  d:=regexp_replace(d,'BEGIN', $skip$BEGIN
 IF COALESCE(to_jsonb(NEW)->'metadata'->>'order_access_link','false')='true' THEN RETURN NEW; END IF;
$skip$);EXECUTE d;
 END IF;
END $translation$;

CREATE TABLE public.direct_order_staff_link_issues(
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE, operation_id uuid NOT NULL,
 actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,key_hash text NOT NULL,public_origin text NOT NULL,
 message_id uuid REFERENCES public.direct_order_messages(id) ON DELETE SET NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(request_id,operation_id),FOREIGN KEY(request_id,key_hash) REFERENCES public.direct_order_access_keys(request_id,key_hash) ON DELETE CASCADE
);
ALTER TABLE public.direct_order_staff_link_issues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_staff_link_issues FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_issue_order_link(p_store_id uuid,p_request_id uuid,p_operation_id uuid,p_access_key text,p_public_origin text,p_send_to_customer boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; issue public.direct_order_staff_link_issues%ROWTYPE; hash text; slug text; link text; mid uuid;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF p_operation_id IS NULL OR COALESCE(p_access_key,'') !~ '^[A-Za-z0-9_-]{43,128}$'
 OR COALESCE(p_public_origin,'') !~ '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?([:]443)?$' OR length(p_public_origin)>200
 OR p_send_to_customer IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_LINK_INPUT_INVALID'; END IF;
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF NOT public.direct_order_access_is_open(r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 SELECT public_slug INTO slug FROM public.direct_order_storefronts WHERE restaurant_id=$1;
 IF slug IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;
 hash:=encode(extensions.digest(convert_to(p_access_key,'UTF8'),'sha256'),'hex');
 SELECT * INTO issue FROM public.direct_order_staff_link_issues WHERE request_id=$2 AND operation_id=$3;
 IF FOUND AND (issue.actor_id IS DISTINCT FROM auth.uid() OR issue.key_hash IS DISTINCT FROM hash OR issue.public_origin IS DISTINCT FROM p_public_origin)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_LINK_RETRY_CHANGED'; END IF;
 IF NOT FOUND THEN
  INSERT INTO public.direct_order_access_keys(request_id,key_hash) VALUES(r.id,hash) ON CONFLICT DO NOTHING;
  INSERT INTO public.direct_order_staff_link_issues(request_id,operation_id,actor_id,key_hash,public_origin)
  VALUES(r.id,$3,auth.uid(),hash,p_public_origin) RETURNING * INTO issue;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_access_keys WHERE request_id=r.id AND key_hash=hash AND revoked_at IS NULL)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 link:=p_public_origin||'/order/'||slug||'/r/'||r.id::text||'#access='||p_access_key;
 IF p_send_to_customer AND issue.message_id IS NULL THEN
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,sender_auth_id,message_type,body,metadata)
  VALUES(r.id,$1,'cashier',auth.uid(),'text',link,jsonb_build_object('order_access_link',true,'operation_id',$3)) RETURNING id INTO mid;
  UPDATE public.direct_order_staff_link_issues SET message_id=mid WHERE request_id=r.id AND operation_id=$3;
 ELSE mid:=issue.message_id; END IF;
 -- Raw keys occur only in the intended private customer message/response,
 -- never in audit data or the issuance journal.
 RETURN jsonb_build_object('url',link,'message_id',mid,'request_id',r.id);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_issue_order_link(uuid,uuid,uuid,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_issue_order_link(uuid,uuid,uuid,text,text,boolean) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_staff_payment_document(p_store_id uuid,p_request_id uuid,p_quote_id uuid,p_quote_version integer,p_include_payment boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; q public.direct_order_quotes%ROWTYPE; bank jsonb; data jsonb; due numeric; items jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.state NOT IN('quoted','awaiting_payment_review') OR r.support_closed_at IS NOT NULL OR r.pii_purged_at IS NOT NULL
 OR EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_DOCUMENT_NOT_ALLOWED'; END IF;
 SELECT * INTO q FROM public.direct_order_quotes WHERE id=$3 AND version=$4 AND request_id=r.id AND restaurant_id=$1 AND status IN('active','locked');
 IF NOT FOUND OR q.amount_finalized_at IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_CHANGED'; END IF;
 SELECT greatest(0,q.final_total-COALESCE(sum(pr.amount),0)) INTO due FROM public.direct_order_payment_receipts pr
 LEFT JOIN public.direct_order_payment_charges c ON c.id=pr.charge_id WHERE pr.request_id=r.id AND c.kind IS DISTINCT FROM 'delivery';
 IF round(due)<=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_DOCUMENT_NOT_ALLOWED'; END IF;
 IF p_include_payment THEN
  SELECT jsonb_build_object('bin',sf.bank_bin,'account_number',sf.bank_account_number,'account_holder',sf.bank_account_holder,'label',COALESCE(NULLIF(sf.bank_label,''),sf.bank_bin))
  INTO bank FROM public.direct_order_storefronts sf WHERE sf.restaurant_id=$1 AND sf.accounting_approved_at IS NOT NULL AND sf.accounting_approved_by IS NOT NULL
  AND sf.bank_bin ~ '^[0-9]{6}$' AND sf.bank_account_number ~ '^[A-Za-z0-9]{5,19}$' AND length(btrim(sf.bank_account_holder)) BETWEEN 2 AND 120;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED'; END IF;
 END IF;
 SELECT jsonb_agg(jsonb_build_object('display_name',i.display_name,'name_ko',i.name_ko,'name_vi',i.name_vi,'name_en',i.name_en,'quantity',i.quantity,'unit_price',i.unit_price,'listed_total',round(i.quantity*i.unit_price,2)) ORDER BY i.sort_order,i.id)
 INTO items FROM public.direct_order_request_items i WHERE i.request_id=r.id AND i.restaurant_id=$1;
 IF jsonb_array_length(COALESCE(items,'[]')) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID'; END IF;
 data:=jsonb_build_object('request_id',r.id,'reference_code',r.reference_code,'quote_id',q.id,'quote_version',q.version,'quoted_at',q.created_at,
  'store_name',(SELECT name FROM public.restaurants WHERE id=$1),'items',items,'menu_pretax',q.menu_pretax,'menu_vat',q.menu_vat,'menu_total',q.menu_total,
  'service_charge_total',q.service_charge_total,'service_charge_vat',q.service_charge_vat,'final_total',q.final_total,'amount_due',round(due),
  'fulfillment_method',r.fulfillment_method,'fulfillment_type',to_jsonb(r)->>'fulfillment_type',
  'bank',bank,'include_payment',p_include_payment,'delivery_payment_mode',q.delivery_payment_mode,'delivery_fee_total',q.delivery_fee_total);
 RETURN jsonb_build_object('data',data,'source_hash',encode(extensions.digest(convert_to(data::text,'UTF8'),'sha256'),'hex'));
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_payment_document(uuid,uuid,uuid,integer,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_payment_document(uuid,uuid,uuid,integer,boolean) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_staff_commit_payment_document(p_store_id uuid,p_request_id uuid,p_quote_id uuid,p_quote_version integer,p_include_payment boolean,p_source_hash text,p_path text,p_filename text,p_mime text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE m public.direct_order_messages%ROWTYPE; source jsonb; size bigint;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF p_path IS NULL OR p_path !~ ('^'||$1::text||'/'||$2::text||'/[0-9a-f-]{36}[.](pdf|png)$')
 OR char_length(COALESCE(p_filename,'')) NOT BETWEEN 1 AND 255 OR p_mime NOT IN('application/pdf','image/png')
 OR p_mime IS NULL OR COALESCE(p_source_hash,'') !~ '^[a-f0-9]{64}$' OR p_include_payment IS NULL
 OR (p_mime='application/pdf' AND p_path NOT LIKE '%.pdf') OR (p_mime='image/png' AND p_path NOT LIKE '%.png') THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 SELECT * INTO m FROM public.direct_order_messages WHERE attachment_storage_path=p_path;
 IF FOUND THEN
  IF m.request_id<>$2 OR m.restaurant_id<>$1 OR m.sender_auth_id IS DISTINCT FROM auth.uid()
  OR m.metadata->>'payment_document_source_hash' IS DISTINCT FROM p_source_hash
  OR m.metadata->>'quote_id' IS DISTINCT FROM $3::text OR m.metadata->>'quote_version' IS DISTINCT FROM $4::text
  OR m.body IS DISTINCT FROM p_filename OR m.metadata->>'include_payment' IS DISTINCT FROM $5::text OR m.metadata->>'mime_type' IS DISTINCT FROM p_mime
  THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
  RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
 END IF;
 source:=public.direct_order_staff_payment_document($1,$2,$3,$4,$5);
 IF source->>'source_hash' IS DISTINCT FROM p_source_hash THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_CHANGED'; END IF;
 SELECT COALESCE((metadata->>'size')::bigint,0) INTO size FROM storage.objects WHERE bucket_id='direct-order-chat' AND name=p_path;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROOF_UPLOAD_INCOMPLETE'; END IF;
 IF size NOT BETWEEN 1 AND 10485760 THEN RAISE EXCEPTION 'DIRECT_ORDER_DOCUMENT_TOO_LARGE'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,sender_auth_id,message_type,body,attachment_storage_path,metadata)
 VALUES($2,$1,'cashier',auth.uid(),'attachment',p_filename,p_path,jsonb_build_object('attachment_kind','chat','mime_type',p_mime,
 'payment_document_source_hash',p_source_hash,'quote_id',$3,'quote_version',$4,'include_payment',$5)) RETURNING * INTO m;
 RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_commit_payment_document(uuid,uuid,uuid,integer,boolean,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_commit_payment_document(uuid,uuid,uuid,integer,boolean,text,text,text,text) TO authenticated,service_role;

DO $verify$ BEGIN
 IF has_function_privilege('authenticated','public.direct_order_quote_preview_core(uuid,uuid,boolean)','EXECUTE')
 OR has_function_privilege('anon','public.direct_order_staff_detail_v7(uuid,uuid)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.direct_order_staff_detail_v7(uuid,uuid)','EXECUTE')
 OR strpos(pg_get_functiondef('public.direct_order_staff_detail_v7(uuid,uuid)'::regprocedure),'direct_order_staff_detail_v6($1,$2)')=0
 OR has_table_privilege('authenticated','public.direct_order_staff_link_issues','SELECT')
 OR NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.direct_order_staff_link_issues'::regclass AND relrowsecurity)
 OR strpos(pg_get_functiondef('public.direct_order_staff_quote_before_final_amount(uuid,uuid,numeric,text)'::regprocedure),'WHEN v_request.delivery_policy_version=2 THEN ''customer_direct''')=0
 THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_GUIDE_BOUNDARY_FAILED'; END IF;
END $verify$;
NOTIFY pgrst,'reload schema';
COMMIT;
