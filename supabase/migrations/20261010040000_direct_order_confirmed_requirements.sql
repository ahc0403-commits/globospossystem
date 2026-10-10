-- Request-linked freeform replies and immutable, Vietnamese print agreements.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

CREATE TABLE public.direct_order_customer_requirements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 source_kind text NOT NULL CHECK(source_kind IN ('order','item')),
 source_id uuid NOT NULL,
 request_text text NOT NULL,
 item_label_vi text,
 source_locale text NOT NULL, customer_context_text text,
 status text NOT NULL DEFAULT 'awaiting_reply' CHECK(status IN ('awaiting_reply','awaiting_customer','confirmed')),
 version integer NOT NULL DEFAULT 1 CHECK(version>0),
 reply_text text, reply_locale text, reply_message_id uuid,
 followup_text text,
 print_request_vi text, print_reply_vi text,
 print_scope text NOT NULL DEFAULT 'both' CHECK(print_scope IN ('preparation','delivery','both')),
 needs_confirmation boolean NOT NULL DEFAULT true,
 confirmed_at timestamptz, confirmation_message_id uuid,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(request_id,source_kind,source_id)
);
CREATE INDEX direct_order_requirements_scope ON public.direct_order_customer_requirements(request_id,status);
ALTER TABLE public.direct_order_customer_requirements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_customer_requirements FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_customer_requirements TO service_role;

-- Source notes are captured in sets. A changed note invalidates its old agreement.
CREATE FUNCTION public.direct_order_capture_requirements() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE changed_ids uuid[];
BEGIN
 IF TG_OP='UPDATE' THEN
  IF TG_TABLE_NAME='direct_order_requests' THEN
   SELECT array_agg(n.id) INTO changed_ids FROM new_requirement_sources n JOIN old_requirement_sources o USING(id)
   WHERE n.customer_note IS DISTINCT FROM o.customer_note OR n.pii_purged_at IS DISTINCT FROM o.pii_purged_at;
  ELSE
   SELECT array_agg(n.id) INTO changed_ids FROM new_requirement_sources n JOIN old_requirement_sources o USING(id)
   WHERE n.item_note IS DISTINCT FROM o.item_note;
  END IF;
 ELSE SELECT array_agg(id) INTO changed_ids FROM new_requirement_sources;
 END IF;
 IF COALESCE(cardinality(changed_ids),0)=0 THEN RETURN NULL; END IF;
 IF TG_TABLE_NAME='direct_order_requests' THEN
  UPDATE public.print_jobs j SET payload=(j.payload-'order_notes')||jsonb_build_object('pii_redacted',true),
   status=CASE WHEN j.status IN ('pending','failed') THEN 'cancelled' ELSE j.status END
   FROM public.direct_order_financials f JOIN new_requirement_sources r ON r.id=f.request_id
   WHERE r.id=ANY(changed_ids) AND j.order_id=f.order_id AND j.restaurant_id=f.restaurant_id AND j.copy_type='request_update' AND r.pii_purged_at IS NOT NULL
   AND NOT COALESCE((j.payload->>'pii_redacted')::boolean,false);
  DELETE FROM public.direct_order_customer_requirements q USING new_requirement_sources r
   WHERE r.id=ANY(changed_ids) AND q.request_id=r.id AND (r.pii_purged_at IS NOT NULL OR (q.source_kind='order' AND NULLIF(btrim(r.customer_note),'') IS NULL));
  INSERT INTO public.direct_order_customer_requirements(request_id,restaurant_id,source_kind,source_id,request_text,source_locale)
   SELECT id,restaurant_id,'order',id,btrim(customer_note),locale FROM new_requirement_sources
   WHERE id=ANY(changed_ids) AND pii_purged_at IS NULL AND NULLIF(btrim(customer_note),'') IS NOT NULL
   ON CONFLICT(request_id,source_kind,source_id) DO UPDATE SET request_text=EXCLUDED.request_text,
    status='awaiting_reply',version=direct_order_customer_requirements.version+1,reply_text=NULL,reply_message_id=NULL,
    print_request_vi=NULL,print_reply_vi=NULL,followup_text=NULL,customer_context_text=NULL,confirmed_at=NULL,confirmation_message_id=NULL,updated_at=now()
    WHERE direct_order_customer_requirements.request_text IS DISTINCT FROM EXCLUDED.request_text;
 ELSE
  -- Quote, reply, confirmation and source changes share one parent-row lock.
  PERFORM r.id FROM public.direct_order_requests r JOIN(SELECT DISTINCT request_id FROM new_requirement_sources WHERE id=ANY(changed_ids)) i ON i.request_id=r.id ORDER BY r.id FOR UPDATE OF r;
  DELETE FROM public.direct_order_customer_requirements q USING new_requirement_sources i
   WHERE i.id=ANY(changed_ids) AND q.source_kind='item' AND q.source_id=i.id AND NULLIF(btrim(i.item_note),'') IS NULL;
  INSERT INTO public.direct_order_customer_requirements(request_id,restaurant_id,source_kind,source_id,request_text,source_locale,item_label_vi)
   SELECT i.request_id,i.restaurant_id,'item',i.id,btrim(i.item_note),r.locale,
    COALESCE(NULLIF(btrim(i.name_vi),''),'Món '||(i.sort_order+1))
   FROM new_requirement_sources i JOIN public.direct_order_requests r ON r.id=i.request_id AND r.restaurant_id=i.restaurant_id
   WHERE i.id=ANY(changed_ids) AND r.pii_purged_at IS NULL AND NULLIF(btrim(i.item_note),'') IS NOT NULL
   ON CONFLICT(request_id,source_kind,source_id) DO UPDATE SET request_text=EXCLUDED.request_text,
    status='awaiting_reply',version=direct_order_customer_requirements.version+1,reply_text=NULL,reply_message_id=NULL,
    print_request_vi=NULL,print_reply_vi=NULL,followup_text=NULL,customer_context_text=NULL,confirmed_at=NULL,confirmation_message_id=NULL,updated_at=now()
    WHERE direct_order_customer_requirements.request_text IS DISTINCT FROM EXCLUDED.request_text;
 END IF;
 RETURN NULL;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_capture_requirements() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_requirements_insert AFTER INSERT ON public.direct_order_requests REFERENCING NEW TABLE AS new_requirement_sources FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_capture_requirements();
CREATE TRIGGER direct_order_requirements_update AFTER UPDATE ON public.direct_order_requests REFERENCING OLD TABLE AS old_requirement_sources NEW TABLE AS new_requirement_sources FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_capture_requirements();
CREATE TRIGGER direct_order_item_requirements_insert AFTER INSERT ON public.direct_order_request_items REFERENCING NEW TABLE AS new_requirement_sources FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_capture_requirements();
CREATE TRIGGER direct_order_item_requirements_update AFTER UPDATE ON public.direct_order_request_items REFERENCING OLD TABLE AS old_requirement_sources NEW TABLE AS new_requirement_sources FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_capture_requirements();
INSERT INTO public.direct_order_customer_requirements(request_id,restaurant_id,source_kind,source_id,request_text,source_locale,item_label_vi)
 SELECT r.id,r.restaurant_id,'order',r.id,btrim(r.customer_note),r.locale,NULL FROM public.direct_order_requests r LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
 WHERE r.pii_purged_at IS NULL AND NULLIF(btrim(r.customer_note),'') IS NOT NULL AND r.state NOT IN ('cancelled','expired','rejected') AND COALESCE(t.status,'pending') NOT IN ('completed','cancelled')
 UNION ALL SELECT i.request_id,i.restaurant_id,'item',i.id,btrim(i.item_note),r.locale,COALESCE(NULLIF(btrim(i.name_vi),''),'Món '||(i.sort_order+1))
 FROM public.direct_order_request_items i JOIN public.direct_order_requests r ON r.id=i.request_id AND r.restaurant_id=i.restaurant_id LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
 WHERE r.pii_purged_at IS NULL AND NULLIF(btrim(i.item_note),'') IS NOT NULL AND r.state NOT IN ('cancelled','expired','rejected') AND COALESCE(t.status,'pending') NOT IN ('completed','cancelled');

-- A single aggregate carries every request and its translations in the detail.
CREATE FUNCTION public.direct_order_requirement_snapshot(p_request_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH translations AS (
  SELECT source_id,source_text,jsonb_object_agg(target_locale,translated_text) FILTER(WHERE status='translated') AS texts,
   CASE WHEN bool_and(status='translated') THEN 'translated' WHEN bool_or(status='failed') THEN 'failed' ELSE 'pending' END AS status
  FROM public.direct_order_translation_jobs WHERE request_id=$1 GROUP BY source_id,source_text
 ) SELECT COALESCE(jsonb_agg((to_jsonb(q)-ARRAY['restaurant_id','request_id'])||jsonb_build_object(
  'request_translations',COALESCE(t.texts,'{}'::jsonb),'reply_translations',COALESCE(rt.texts,m.metadata->'translations','{}'::jsonb),
  'reply_translation_status',COALESCE(rt.status,'original')) ORDER BY q.created_at,q.id),'[]'::jsonb)
 FROM public.direct_order_customer_requirements q LEFT JOIN translations t ON t.source_id=q.source_id AND t.source_text=q.request_text
 LEFT JOIN public.direct_order_messages m ON m.id=q.reply_message_id
 LEFT JOIN translations rt ON rt.source_id=m.id AND rt.source_text=m.body WHERE q.request_id=$1;
$$;
REVOKE ALL ON FUNCTION public.direct_order_requirement_snapshot(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_public_status_v9(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE b jsonb;
BEGIN
 b:=public.direct_order_public_status_v8($1,$2,$3);
 RETURN b||jsonb_build_object('requirements',public.direct_order_requirement_snapshot($3));
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v9(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v9(uuid,text,uuid) TO service_role;
CREATE FUNCTION public.direct_order_staff_detail_v5(p_store_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;
BEGIN
 b:=public.direct_order_staff_detail_v4($1,$2);
 RETURN b||jsonb_build_object('requirements',public.direct_order_requirement_snapshot($2),'delivery',(b->'delivery')||jsonb_build_object('utensils_requested',(SELECT utensils_requested FROM public.direct_order_requests WHERE id=$2)));
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v5(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v5(uuid,uuid) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_staff_list_v4(p_store_id uuid,p_states text[] DEFAULT NULL,p_limit integer DEFAULT 100,p_fulfillment_type text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
 WITH page AS MATERIALIZED (SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_order_staff_list_v3($1,$2,$3,$4)) WITH ORDINALITY e),
 counts AS (SELECT q.request_id,count(*) FILTER(WHERE q.status='awaiting_reply') AS reply_due,
 count(*) FILTER(WHERE q.status='awaiting_customer') AS confirmation_due FROM public.direct_order_customer_requirements q
 JOIN page p ON p.value->>'id'=q.request_id::text GROUP BY q.request_id)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('request_reply_due',COALESCE(c.reply_due,0),'request_confirmation_due',COALESCE(c.confirmation_due,0)) ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN counts c ON c.request_id::text=p.value->>'id';
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_v4(uuid,text[],integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v4(uuid,text[],integer,text) TO authenticated,service_role;

-- Gate the public quote entry points inside the same request lock as replies.
ALTER FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) RENAME TO direct_order_quote_before_requirements;
REVOKE ALL ON FUNCTION public.direct_order_quote_before_requirements(uuid,uuid,numeric,text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_quote_with_payment_mode(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text DEFAULT NULL,p_delivery_payment_mode text DEFAULT 'store_prepaid') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE request_id=$2 AND status<>'confirmed') THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENTS_PENDING'; END IF;
 RETURN public.direct_order_quote_before_requirements($1,$2,$3,$4,$5);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.direct_order_staff_quote(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_staff_quote_with_payment_mode($1,$2,$3,$4,'store_prepaid');
$$;

-- Reviewed Vietnamese text is the print authority; source-language history stays
-- in the chat snapshot. Never drop unsupported Korean characters in ESC/POS.
CREATE FUNCTION public.direct_order_requirement_print_snapshot(p_request_id uuid,p_scope text DEFAULT 'receipt') RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT jsonb_build_object('confirmed_requirements',COALESCE(jsonb_agg(jsonb_build_object(
  'id',id,'version',version,'request_text',request_text,'reply_text',reply_text,'source_locale',source_locale,
  'print_request_vi',print_request_vi,'print_reply_vi',print_reply_vi,'confirmed_at',confirmed_at,'customer_context_text',customer_context_text,
  'item_label_vi',item_label_vi,'print_scope',print_scope) ORDER BY created_at,id),'[]'::jsonb),
  'order_notes',string_agg(COALESCE(item_label_vi||': ','')||'Yêu cầu: '||print_request_vi||E'\nĐã thống nhất: '||print_reply_vi,E'\n\n' ORDER BY created_at,id))
 FROM public.direct_order_customer_requirements WHERE request_id=$1 AND status='confirmed'
 AND ($2='receipt' OR print_scope='both' OR print_scope=$2);
$$;
REVOKE ALL ON FUNCTION public.direct_order_requirement_print_snapshot(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE TABLE public.direct_order_requirement_addenda(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
 requirement_id uuid NOT NULL REFERENCES public.direct_order_customer_requirements(id) ON DELETE CASCADE,
 version integer NOT NULL, snapshot jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(requirement_id,version)
);
ALTER TABLE public.direct_order_requirement_addenda ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_requirement_addenda FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_requirement_addenda TO service_role;
ALTER TABLE public.print_jobs DROP CONSTRAINT print_jobs_copy_type_check;
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_copy_type_check CHECK(copy_type IN ('kitchen','floor','tray','confirmation','receipt','delivery_driver_receipt','request_update'));

CREATE FUNCTION public.direct_order_emit_requirement_addendum(p_requirement_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE q public.direct_order_customer_requirements%ROWTYPE; o uuid; ref text; memo jsonb; n integer; inserted uuid; v_mode text; v_session uuid;
BEGIN
 SELECT * INTO q FROM public.direct_order_customer_requirements WHERE id=$1 AND status='confirmed';
 IF NOT FOUND THEN RETURN; END IF;
 SELECT f.order_id,r.reference_code,COALESCE(ord.fulfillment_mode_snapshot,'pos_print'),ses.id INTO o,ref,v_mode,v_session FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id JOIN public.orders ord ON ord.id=f.order_id AND ord.restaurant_id=q.restaurant_id LEFT JOIN public.emergency_fulfillment_sessions ses ON ses.restaurant_id=q.restaurant_id AND ses.status='active' WHERE f.request_id=q.request_id;
 IF o IS NULL OR NOT (EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o) OR EXISTS(SELECT 1 FROM public.digital_receipts WHERE order_id=o)) THEN RETURN; END IF;
 memo:=jsonb_build_object('id',q.id,'version',q.version,'confirmed_at',q.confirmed_at,'request_text',q.request_text,
  'reply_text',q.reply_text,'customer_context_text',q.customer_context_text,'print_request_vi',q.print_request_vi,'print_reply_vi',q.print_reply_vi,'item_label_vi',q.item_label_vi,'print_scope',q.print_scope,
  'order_notes',COALESCE(q.item_label_vi||': ','')||'Yêu cầu: '||q.print_request_vi||E'\nĐã thống nhất: '||q.print_reply_vi);
 INSERT INTO public.direct_order_requirement_addenda(request_id,requirement_id,version,snapshot) VALUES(q.request_id,q.id,q.version,memo) ON CONFLICT DO NOTHING RETURNING id INTO inserted;
 IF inserted IS NULL THEN RETURN; END IF;
 SELECT COALESCE(max(batch_no),0)+1 INTO n FROM public.print_jobs WHERE order_id=o AND copy_type='request_update';
 -- Only route to the existing order's printers, grouped by destination. No PII,
 -- totals, payment operation, or rewriting/reprinting an issued original.
 WITH routes AS (
  SELECT destination_id,bool_or(copy_type='receipt') AS receipt_route FROM public.print_jobs WHERE order_id=o AND destination_id IS NOT NULL
   AND (copy_type='receipt' OR (copy_type IN ('kitchen','tray','floor','confirmation') AND q.print_scope IN ('preparation','both'))
    OR (copy_type='delivery_driver_receipt' AND q.print_scope IN ('delivery','both'))) GROUP BY destination_id
 ) INSERT INTO public.print_jobs(restaurant_id,order_id,copy_type,batch_no,destination_id,fulfillment_mode_snapshot,emergency_session_id,payload)
 SELECT q.restaurant_id,o,'request_update',n,destination_id,v_mode,v_session,jsonb_build_object('ticket','request_update','request_update',true,
  'request_update_mode',v_mode,'request_update_session',v_session,'request_update_receipt',receipt_route,'batch_no',n,'direct_order_reference',ref,'at',now(),'items','[]'::jsonb,'order_notes',memo->>'order_notes','requirement_addendum_id',inserted)
 FROM routes;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_emit_requirement_addendum(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.direct_order_staff_reply_requirement(
 p_store_id uuid,p_request_id uuid,p_requirement_id uuid,p_expected_version integer,p_mutation_id uuid,
 p_body text,p_locale text,p_needs_confirmation boolean,p_print_request_vi text,p_print_reply_vi text,p_print_scope text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE q public.direct_order_customer_requirements%ROWTYPE; r public.direct_order_requests%ROWTYPE; mid uuid; replay public.direct_order_messages%ROWTYPE;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.pii_purged_at IS NOT NULL OR r.support_closed_at IS NOT NULL OR r.state IN ('cancelled','expired','rejected') OR NOT public.direct_order_access_is_open(r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 SELECT * INTO q FROM public.direct_order_customer_requirements WHERE id=$3 AND request_id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_NOT_FOUND'; END IF;
 IF $5 IS NULL OR length(COALESCE(btrim($6),'')) NOT BETWEEN 1 AND 2000 OR COALESCE($7,'') NOT IN ('ko','vi','en') OR $8 IS NULL
 OR COALESCE($11,'') NOT IN ('preparation','delivery','both') OR length(COALESCE(btrim($9),'')) NOT BETWEEN 1 AND 2000
 OR length(COALESCE(btrim($10),'')) NOT BETWEEN 1 AND 2000 OR $9 ~ '[[:cntrl:]]' OR $10 ~ '[[:cntrl:]]'
 OR $9 !~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$' OR $10 !~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$' THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID'; END IF;
 -- A retry of the same operation returns current data and never overwrites a
 -- newer reply. A changed operation must carry a fresh UUID and version.
 SELECT * INTO replay FROM public.direct_order_messages WHERE request_id=$2 AND metadata->>'requirement_mutation_id'=$5::text;
 IF FOUND THEN
  IF replay.body IS DISTINCT FROM btrim($6) OR replay.metadata->>'requirement_id' IS DISTINCT FROM q.id::text
   OR replay.metadata->>'print_request_vi' IS DISTINCT FROM btrim($9) OR replay.metadata->>'print_reply_vi' IS DISTINCT FROM btrim($10)
   OR replay.metadata->>'print_scope' IS DISTINCT FROM $11 OR replay.metadata->>'reply_locale' IS DISTINCT FROM $7
   OR (replay.metadata->>'needs_confirmation')::boolean IS DISTINCT FROM $8 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
  RETURN public.direct_order_staff_detail_v5($1,$2);
 END IF;
 IF $4 IS DISTINCT FROM q.version THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES($2,$1,'cashier','text',btrim($6),jsonb_build_object('requirement_id',q.id,'requirement_version',q.version+1,
  'request_text',q.request_text,'requirement_mutation_id',$5,'needs_confirmation',$8,'reply_locale',$7,'print_scope',$11,'print_request_vi',btrim($9),'print_reply_vi',btrim($10))) RETURNING id INTO mid;
 UPDATE public.direct_order_customer_requirements SET version=version+1,reply_text=btrim($6),reply_locale=$7,reply_message_id=mid,
  needs_confirmation=$8,print_request_vi=btrim($9),print_reply_vi=btrim($10),print_scope=$11,
  status=CASE WHEN $8 THEN 'awaiting_customer' ELSE 'confirmed' END,confirmed_at=CASE WHEN $8 THEN NULL ELSE now() END,
  confirmation_message_id=NULL,followup_text=NULL,updated_at=now() WHERE id=q.id;
 IF NOT $8 THEN PERFORM public.direct_order_emit_requirement_addendum(q.id); END IF;
 UPDATE public.direct_order_requests SET updated_at=now() WHERE id=$2;
 RETURN public.direct_order_staff_detail_v5($1,$2);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_reply_requirement(uuid,uuid,uuid,integer,uuid,text,text,boolean,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_reply_requirement(uuid,uuid,uuid,integer,uuid,text,text,boolean,text,text,text) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_public_decide_requirement(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_requirement_id uuid,p_expected_version integer,p_reply_message_id uuid,p_accept boolean,p_body text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; r public.direct_order_requests%ROWTYPE; q public.direct_order_customer_requirements%ROWTYPE; mid uuid;
BEGIN
 s:=public.direct_order_validate_session($1,$2);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$3 AND session_id=s.id AND restaurant_id=s.restaurant_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.state IN ('cancelled','expired','rejected') OR NOT public.direct_order_access_is_open(r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 SELECT * INTO q FROM public.direct_order_customer_requirements WHERE id=$4 AND request_id=r.id AND restaurant_id=r.restaurant_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_NOT_FOUND'; END IF;
 IF $7 IS NULL OR (NOT $7 AND length(COALESCE(btrim($8),'')) NOT BETWEEN 1 AND 2000) OR ($7 AND NULLIF(btrim($8),'') IS NOT NULL) THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID'; END IF;
 IF $5 IS DISTINCT FROM q.version OR $6 IS DISTINCT FROM q.reply_message_id OR $6 IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
 IF $7 AND q.status='confirmed' AND q.confirmation_message_id IS NOT NULL THEN RETURN public.direct_order_public_status_v9($1,$2,$3); END IF;
 IF q.status<>'awaiting_customer' THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES(r.id,r.restaurant_id,'customer','text',CASE WHEN $7 THEN CASE r.locale WHEN 'ko' THEN '네, 이 내용으로 확정해주세요.' WHEN 'vi' THEN 'Tôi đồng ý với nội dung này.' ELSE 'I agree to these details.' END ELSE btrim($8) END,
  jsonb_build_object('requirement_id',q.id,'requirement_version',q.version,'reply_message_id',q.reply_message_id,'requirement_accepted',$7)) RETURNING id INTO mid;
 UPDATE public.direct_order_customer_requirements SET status=CASE WHEN $7 THEN 'confirmed' ELSE 'awaiting_reply' END,
  version=version+CASE WHEN $7 THEN 0 ELSE 1 END,confirmed_at=CASE WHEN $7 THEN now() ELSE NULL END,
  confirmation_message_id=CASE WHEN $7 THEN mid ELSE NULL END,followup_text=CASE WHEN $7 THEN NULL ELSE btrim($8) END,
  customer_context_text=CASE WHEN $7 THEN customer_context_text ELSE btrim($8) END,updated_at=now() WHERE id=q.id;
 IF $7 THEN PERFORM public.direct_order_emit_requirement_addendum(q.id); END IF;
 UPDATE public.direct_order_requests SET updated_at=now() WHERE id=r.id;
 RETURN public.direct_order_public_status_v9($1,$2,$3);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_decide_requirement(uuid,text,uuid,uuid,integer,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_decide_requirement(uuid,text,uuid,uuid,integer,uuid,boolean,text) TO service_role;

-- New documents contain only confirmed instructions. Raw pending notes remain
-- visible in chat, never presented as an approved preparation instruction.
CREATE FUNCTION public.direct_order_enrich_confirmed_print() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE rid uuid; b jsonb; scope text;
BEGIN
 IF NEW.copy_type='request_update' THEN RETURN NEW; END IF;
 SELECT request_id INTO rid FROM public.direct_order_financials WHERE order_id=NEW.order_id AND restaurant_id=NEW.restaurant_id;
 IF rid IS NULL THEN RETURN NEW; END IF;
 scope:=CASE NEW.copy_type WHEN 'receipt' THEN 'receipt' WHEN 'delivery_driver_receipt' THEN 'delivery' ELSE 'preparation' END;
 b:=public.direct_order_requirement_print_snapshot(rid,scope);
 NEW.payload:=NEW.payload||b||jsonb_build_object('items',COALESCE((SELECT jsonb_agg(e.value-'notes' ORDER BY e.ordinality) FROM jsonb_array_elements(COALESCE(NEW.payload->'items','[]'::jsonb)) WITH ORDINALITY e),'[]'::jsonb));
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_confirmed_print() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzz_direct_order_confirmed_print BEFORE INSERT ON public.print_jobs FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_confirmed_print();
CREATE FUNCTION public.direct_order_enrich_confirmed_digital() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE rid uuid;
BEGIN
 SELECT request_id INTO rid FROM public.direct_order_financials WHERE order_id=NEW.order_id AND restaurant_id=NEW.restaurant_id;
 IF rid IS NOT NULL AND NEW.combined_payment_group_id IS NULL THEN
  NEW.snapshot:=NEW.snapshot||public.direct_order_requirement_print_snapshot(rid)||jsonb_build_object('items',COALESCE((SELECT jsonb_agg(e.value-'notes' ORDER BY e.ordinality) FROM jsonb_array_elements(COALESCE(NEW.snapshot->'items','[]'::jsonb)) WITH ORDINALITY e),'[]'::jsonb));
 END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_confirmed_digital() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzz_direct_order_confirmed_digital BEFORE INSERT ON public.digital_receipts FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_confirmed_digital();

-- Existing context consumers (manual receipt and KDS) receive one agreed block.
ALTER FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) RENAME TO direct_order_packing_before_requirements;
REVOKE ALL ON FUNCTION public.direct_order_packing_before_requirements(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_receipt_packing_context(p_store_id uuid,p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb; rid uuid;
BEGIN
 b:=public.direct_order_packing_before_requirements($1,$2);
 SELECT request_id INTO rid FROM public.direct_order_financials WHERE order_id=$2 AND restaurant_id=$1;
 RETURN CASE WHEN rid IS NULL THEN b ELSE b||public.direct_order_requirement_print_snapshot(rid) END;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) TO authenticated,service_role;

ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb) RENAME TO emergency_orders_before_requirements;
REVOKE ALL ON FUNCTION public.emergency_orders_before_requirements(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.emergency_enrich_start_ready_orders(p_orders jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH page AS MATERIALIZED (SELECT e.value,e.ordinality FROM jsonb_array_elements(public.emergency_orders_before_requirements($1)) WITH ORDINALITY e),
 scope AS MATERIALIZED (SELECT p.ordinality,f.request_id FROM page p JOIN public.emergency_order_queue e ON e.id=NULLIF(p.value->>'queue_id','')::uuid JOIN public.direct_order_financials f ON f.order_id=e.order_id),
 notes AS (SELECT q.request_id,string_agg(COALESCE(q.item_label_vi||': ','')||q.print_reply_vi,E'\n' ORDER BY q.created_at,q.id) AS text
 FROM public.direct_order_customer_requirements q WHERE q.request_id IN(SELECT request_id FROM scope) AND q.status='confirmed' AND q.print_scope IN ('preparation','both') GROUP BY q.request_id)
 SELECT COALESCE(jsonb_agg(p.value||CASE WHEN s.request_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('direct_order_packing',COALESCE(p.value->'direct_order_packing','{}'::jsonb)||jsonb_build_object('confirmed_notes',n.text)) END ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN scope s USING(ordinality) LEFT JOIN notes n ON n.request_id=s.request_id;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) RENAME TO direct_delivery_tickets_before_requirements;
REVOKE ALL ON FUNCTION public.direct_delivery_tickets_before_requirements(uuid,text[],integer) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_delivery_ticket_list_v3(p_store_id uuid,p_statuses text[] DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
 WITH page AS MATERIALIZED(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_delivery_tickets_before_requirements($1,$2,$3)) WITH ORDINALITY e),
 notes AS(SELECT q.request_id,string_agg(COALESCE(q.item_label_vi||': ','')||q.print_reply_vi,E'\n' ORDER BY q.created_at,q.id) AS text
 FROM public.direct_order_customer_requirements q WHERE q.request_id IN(SELECT (value->>'request_id')::uuid FROM page)
 AND q.status='confirmed' AND q.print_scope IN('preparation','both') GROUP BY q.request_id)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('confirmed_notes',n.text) ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN notes n ON n.request_id::text=p.value->>'request_id';
$$;
REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) TO authenticated,service_role;

ALTER FUNCTION public.get_public_receipt(text) RENAME TO get_public_receipt_before_requirements;
REVOKE ALL ON FUNCTION public.get_public_receipt_before_requirements(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.get_public_receipt(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE b jsonb; addenda jsonb;
BEGIN
 b:=public.get_public_receipt_before_requirements($1);
 IF b IS NULL THEN RETURN NULL; END IF;
 WITH receipt AS MATERIALIZED(SELECT d.snapshot,f.request_id FROM public.digital_receipts d
  JOIN public.direct_order_financials f ON f.order_id=d.order_id AND f.restaurant_id=d.restaurant_id WHERE d.id=(b->>'receipt_id')::uuid),
 recorded AS MATERIALIZED(SELECT c.value->>'id' AS id,max((c.value->>'version')::integer) AS version FROM receipt r
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.snapshot->'confirmed_requirements','[]'::jsonb)) c GROUP BY c.value->>'id')
 SELECT COALESCE(jsonb_agg(a.snapshot ORDER BY a.created_at,a.id),'[]'::jsonb) INTO addenda
 FROM receipt r JOIN public.direct_order_requirement_addenda a ON a.request_id=r.request_id
 LEFT JOIN recorded c ON c.id=a.requirement_id::text WHERE c.version IS NULL OR c.version<a.version;
 RETURN b||jsonb_build_object('request_addenda',addenda);
END; $$;
REVOKE ALL ON FUNCTION public.get_public_receipt(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_receipt(text) TO service_role;

-- Addendum copies use the normal queue, but skip financial snapshot enrichment.
DO $memo_guards$
DECLARE sig text; d text;
BEGIN
 FOREACH sig IN ARRAY ARRAY['public.direct_order_enrich_print_fulfillment()','public.direct_order_final_receipt_print()'] LOOP
  -- The second canonical function is located by its trigger below.
  IF sig='public.direct_order_final_receipt_print()' THEN
   SELECT p.oid::regprocedure::text INTO sig FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid='public.print_jobs'::regclass AND t.tgname='zzz_direct_order_final_receipt';
  END IF;
  SELECT pg_get_functiondef(sig::regprocedure) INTO d;
  IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_PRINT_DRIFT'; END IF;
  EXECUTE replace(d,E'BEGIN\n',E'BEGIN\n IF NEW.copy_type=''request_update'' THEN RETURN NEW; END IF;\n');
 END LOOP;
END; $memo_guards$;

-- A memo reprint stays on its original destination, including receipt printers.
DO $memo_reprint$
DECLARE d text; anchor text:='  IF v_source.copy_type IN (''floor'', ''confirmation'') THEN';
BEGIN
 SELECT pg_get_functiondef('public.reprint_print_job(uuid)'::regprocedure) INTO d;
 IF strpos(d,anchor)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_PRINT_DRIFT'; END IF;
 EXECUTE replace(d,anchor,E'  IF v_source.copy_type=''request_update'' THEN\n    SELECT id INTO v_destination_id FROM public.printer_destinations WHERE id=v_source.destination_id AND restaurant_id=v_source.restaurant_id AND is_active=true;\n  ELSIF v_source.copy_type IN (''floor'', ''confirmation'') THEN');
END; $memo_reprint$;

-- Memos already carry trusted mode and destination purpose, captured once by
-- the private emitter. Authenticated clients have no INSERT permission.
DO $memo_routing$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.emergency_hold_print_job()'::regprocedure) INTO d;
 IF strpos(d,'SELECT order_row.fulfillment_mode_snapshot')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_PRINT_DRIFT'; END IF;
 EXECUTE replace(d,'  SELECT order_row.fulfillment_mode_snapshot',$memo$  IF NEW.copy_type='request_update' THEN
    NEW.fulfillment_mode_snapshot:=COALESCE(NEW.payload->>'request_update_mode',NEW.fulfillment_mode_snapshot);
    NEW.emergency_session_id:=COALESCE((NEW.payload->>'request_update_session')::uuid,NEW.emergency_session_id);
    IF NEW.fulfillment_mode_snapshot='paperless' AND NOT COALESCE((NEW.payload->>'request_update_receipt')::boolean,false) THEN
      NEW.emergency_held_at:=now(); NEW.emergency_resolution:='digital_completed';
      NEW.status:='cancelled'; NEW.last_error:='PAPERLESS_DIGITAL_ROUTING';
    END IF;
    RETURN NEW;
  END IF;
  SELECT order_row.fulfillment_mode_snapshot$memo$);
END; $memo_routing$;
-- Only upgraded agents can claim the new memo copy. Existing agents retain
-- normal jobs and leave request_update pending rather than printing a kitchen slip.
DO $claim_capability$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.claim_print_jobs(uuid,integer)'::regprocedure) INTO d;
 IF strpos(d,'AND emergency_held_at IS NULL')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_PRINT_DRIFT'; END IF;
 EXECUTE replace(d,'public.claim_print_jobs(', 'public.claim_print_jobs_v2(');
 EXECUTE replace(d,'AND emergency_held_at IS NULL','AND emergency_held_at IS NULL AND copy_type <> ''request_update'' AND COALESCE(payload->>''utensils_requested'',''true'') <> ''false''');
END; $claim_capability$;
REVOKE ALL ON FUNCTION public.claim_print_jobs_v2(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.claim_print_jobs_v2(uuid,integer) TO authenticated,service_role;
DO $verify$
BEGIN
 IF has_table_privilege('authenticated','public.direct_order_customer_requirements','SELECT')
 OR has_function_privilege('authenticated','public.direct_order_public_decide_requirement(uuid,text,uuid,uuid,integer,uuid,boolean,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_quote_before_requirements(uuid,uuid,numeric,text,text)','EXECUTE')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.print_jobs'::regclass AND tgname='zzzz_direct_order_confirmed_print' AND tgenabled='O') THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_PERMISSION_DRIFT'; END IF;
END; $verify$;
COMMIT;
