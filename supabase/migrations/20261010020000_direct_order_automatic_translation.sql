-- Translation never blocks payment or fulfillment, and never overwrites source text.
-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.direct_order_translation_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
 source_id uuid NOT NULL,source_kind text NOT NULL CHECK(source_kind IN ('message','customer_note','item_note','cashier_note')),
 source_hash text GENERATED ALWAYS AS (md5(source_text)) STORED,
 source_text text NOT NULL CHECK(char_length(source_text) BETWEEN 1 AND 2000),target_locale text NOT NULL CHECK(target_locale IN ('ko','vi','en')),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','processing','translated','failed')),
 translated_text text,attempts integer NOT NULL DEFAULT 0,lease_id uuid,lease_until timestamptz,
 retry_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz,
 UNIQUE(source_kind,source_id,source_hash,target_locale));
CREATE INDEX direct_order_translation_claim ON public.direct_order_translation_jobs(retry_at,created_at) WHERE status IN ('pending','processing');
CREATE INDEX direct_order_translation_request ON public.direct_order_translation_jobs(request_id,source_kind,source_id);
ALTER TABLE public.direct_order_translation_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_translation_jobs FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_translation_jobs TO service_role;
CREATE FUNCTION public.direct_order_enqueue_translation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE kind text;body text;rid uuid;target text;
BEGIN
 IF TG_TABLE_NAME='direct_order_messages' THEN
  IF NEW.message_type<>'text' OR NEW.sender_type NOT IN ('customer','cashier') THEN RETURN NEW; END IF;
  kind:='message';body:=NEW.body;rid:=NEW.request_id;
  SELECT CASE WHEN NEW.sender_type='customer' THEN 'vi' ELSE locale END INTO target FROM public.direct_order_requests WHERE id=rid;
 ELSIF TG_TABLE_NAME='direct_order_requests' THEN
  kind:='customer_note';body:=NEW.customer_note;rid:=NEW.id;target:='vi';
 ELSIF TG_TABLE_NAME='direct_order_request_items' THEN
  kind:='item_note';body:=NEW.item_note;rid:=NEW.request_id;target:='vi';
 ELSE
  kind:='cashier_note';body:=NEW.cashier_note;rid:=NEW.request_id;
  SELECT locale INTO target FROM public.direct_order_requests WHERE id=rid;
 END IF;
 IF NULLIF(btrim(body),'') IS NOT NULL THEN
  INSERT INTO public.direct_order_translation_jobs(request_id,source_id,source_kind,source_text,target_locale)
   VALUES(rid,NEW.id,kind,body,target) ON CONFLICT DO NOTHING;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER direct_order_translate_message AFTER INSERT ON public.direct_order_messages FOR EACH ROW EXECUTE FUNCTION public.direct_order_enqueue_translation();
CREATE TRIGGER direct_order_translate_request_note AFTER INSERT OR UPDATE OF customer_note ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.direct_order_enqueue_translation();
CREATE TRIGGER direct_order_translate_item_note AFTER INSERT OR UPDATE OF item_note ON public.direct_order_request_items FOR EACH ROW EXECUTE FUNCTION public.direct_order_enqueue_translation();
CREATE TRIGGER direct_order_translate_cashier_note AFTER INSERT OR UPDATE OF cashier_note ON public.direct_order_quotes FOR EACH ROW EXECUTE FUNCTION public.direct_order_enqueue_translation();
CREATE FUNCTION public.claim_direct_order_translations(p_limit integer DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 UPDATE public.direct_order_translation_jobs SET status='failed',lease_until=NULL WHERE status='processing' AND lease_until<=now() AND attempts>=5;
 -- Keep each provider batch within one customer's order and a text budget.
 -- Serve the least recently processed order first for fairness between chats.
 WITH eligible AS MATERIALIZED (
 SELECT j.id,j.request_id,j.created_at,char_length(j.source_text) chars FROM public.direct_order_translation_jobs j
 JOIN public.direct_order_requests r ON r.id=j.request_id
 WHERE j.status IN ('pending','processing') AND j.retry_at<=now() AND (j.lease_until IS NULL OR j.lease_until<=now())
 AND j.attempts<5 AND r.pii_purged_at IS NULL AND r.support_closed_at IS NULL
 ), turns AS (
 SELECT request_id,max(COALESCE(completed_at,retry_at)) served FROM public.direct_order_translation_jobs WHERE attempts>0 GROUP BY request_id
 ), next_order AS (
 SELECT e.request_id FROM eligible e LEFT JOIN turns t USING(request_id) GROUP BY e.request_id,t.served
 ORDER BY t.served NULLS FIRST,min(e.created_at),e.request_id LIMIT 1
 ), budget AS (
 SELECT e.*,sum(chars) OVER(ORDER BY created_at,id) total_chars FROM eligible e JOIN next_order n USING(request_id)
 ), candidates AS (
 SELECT j.id FROM public.direct_order_translation_jobs j JOIN budget e USING(id) WHERE e.total_chars<=5000
 ORDER BY e.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT least(greatest(COALESCE($1,10),1),10)
 ), claimed AS (
 UPDATE public.direct_order_translation_jobs j SET status='processing',attempts=attempts+1,lease_id=gen_random_uuid(),lease_until=now()+interval '90 seconds'
 FROM candidates c WHERE j.id=c.id RETURNING j.*)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'lease_id',lease_id,'text',source_text,'target_locale',target_locale)),'[]'::jsonb) INTO result FROM claimed;
 RETURN result;
END; $$;
CREATE FUNCTION public.complete_direct_order_translations(p_results jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE entry jsonb;j public.direct_order_translation_jobs%ROWTYPE;v_translation text;done int:=0;
BEGIN
 IF jsonb_typeof(p_results)<>'array' OR jsonb_array_length(p_results)>10 THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_INVALID'; END IF;
 FOR entry IN SELECT value FROM jsonb_array_elements(p_results) LOOP
  SELECT * INTO j FROM public.direct_order_translation_jobs WHERE id=(entry->>'id')::uuid AND lease_id=(entry->>'lease_id')::uuid AND status='processing' AND lease_until>now() FOR UPDATE;
  IF NOT FOUND THEN CONTINUE; END IF;
  v_translation:=NULLIF(btrim(entry->>'translated_text'),'');
  IF v_translation IS NOT NULL AND char_length(v_translation)<=6000 AND EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=j.request_id AND pii_purged_at IS NULL AND support_closed_at IS NULL) THEN
   UPDATE public.direct_order_translation_jobs SET status='translated',translated_text=v_translation,completed_at=now(),lease_until=NULL WHERE id=j.id;
   IF j.source_kind='message' THEN
    UPDATE public.direct_order_messages SET metadata=metadata||jsonb_build_object('translations',COALESCE(metadata->'translations','{}'::jsonb)||jsonb_build_object(j.target_locale,v_translation),'translation_status','translated')
    WHERE id=j.source_id AND body=j.source_text;
   ELSE
    -- Notify existing live consumers without changing a frozen quote/item snapshot.
    UPDATE public.direct_order_requests SET updated_at=now() WHERE id=j.request_id;
   END IF;
   done:=done+1;
  ELSE
   UPDATE public.direct_order_translation_jobs SET status=CASE WHEN attempts>=5 THEN 'failed' ELSE 'pending' END,
    retry_at=now()+make_interval(secs=>least(300,attempts*30)),lease_until=NULL WHERE id=j.id;
  END IF;
 END LOOP;
 RETURN done;
END; $$;
REVOKE ALL ON FUNCTION public.claim_direct_order_translations(integer),public.complete_direct_order_translations(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_direct_order_translations(integer),public.complete_direct_order_translations(jsonb) TO service_role;
-- One detail query adds translations to messages and all notes together.
CREATE FUNCTION public.direct_order_enrich_translations(p_base jsonb,p_request_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH notes AS (
 SELECT source_kind,source_id,source_text,jsonb_object_agg(target_locale,translated_text) FILTER(WHERE status='translated') translations,
 CASE WHEN bool_and(status='translated') THEN 'translated' WHEN bool_or(status='failed') THEN 'failed' ELSE 'pending' END status
 FROM public.direct_order_translation_jobs WHERE request_id=$2 GROUP BY source_kind,source_id,source_text
 ), messages AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('metadata',m.metadata||jsonb_build_object('translation_status',COALESCE(n.status,'original'))) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'messages','[]'::jsonb)) WITH ORDINALITY e LEFT JOIN public.direct_order_messages m ON m.id=(e.value->>'id')::uuid
 LEFT JOIN notes n ON n.source_kind='message' AND n.source_id=m.id AND n.source_text=m.body
 ), items AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'items','[]'::jsonb)) WITH ORDINALITY e
 LEFT JOIN public.direct_order_request_items i ON i.request_id=$2 AND i.menu_item_id::text=e.value->>'menu_item_id' AND i.item_note IS NOT DISTINCT FROM COALESCE(e.value->>'note',e.value->>'item_note')
 LEFT JOIN notes n ON n.source_kind='item_note' AND n.source_id=i.id AND n.source_text=i.item_note
 ), quotes AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'quotes','[]'::jsonb)) WITH ORDINALITY e LEFT JOIN notes n ON n.source_kind='cashier_note' AND n.source_id::text=e.value->>'id' AND n.source_text=e.value->>'cashier_note'
 )
 SELECT $1||jsonb_build_object('messages',messages.value,'items',items.value)||CASE WHEN $1?'quotes' THEN jsonb_build_object('quotes',quotes.value) ELSE '{}'::jsonb END
 ||CASE WHEN jsonb_typeof($1->'quote')='object' THEN jsonb_build_object('quote',($1->'quote')||(SELECT jsonb_build_object('cashier_note',q.cashier_note,'note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) FROM public.direct_order_quotes q LEFT JOIN notes n ON n.source_kind='cashier_note' AND n.source_id=q.id AND n.source_text=q.cashier_note WHERE q.id::text=$1->'quote'->>'id')) ELSE '{}'::jsonb END
 ||CASE WHEN $1?'request' THEN jsonb_build_object('request',($1->'request')||jsonb_build_object('note_translations',COALESCE((SELECT translations FROM notes WHERE source_kind='customer_note' AND source_text=$1->'request'->>'customer_note'),'{}'::jsonb),'translation_status',COALESCE((SELECT status FROM notes WHERE source_kind='customer_note' AND source_text=$1->'request'->>'customer_note'),'original'))) ELSE '{}'::jsonb END
 FROM messages CROSS JOIN items CROSS JOIN quotes;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_translations(jsonb,uuid) FROM PUBLIC,anon,authenticated;
-- Existing customer status versions keep their strict payload contracts.
CREATE FUNCTION public.direct_order_public_status_v7(p_session_id uuid,p_secret_hash text,p_request_id uuid)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_enrich_translations(public.direct_order_public_status_v6($1,$2,$3),$3);
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v7(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v7(uuid,text,uuid) TO service_role;
DO $details$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_detail_v3(uuid,uuid)'::regprocedure) INTO d;
 IF d !~ 'RETURN[[:space:]]+v_base[[:space:]]*[|][|]' THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_DETAIL_DRIFT'; END IF;
 d:=regexp_replace(d,'RETURN[[:space:]]+v_base[[:space:]]*[|][|]','RETURN public.direct_order_enrich_translations(v_base,p_request_id) ||');
 EXECUTE d;
END; $details$;
-- Kitchen pages enrich every item in a single query; no per-ticket RPC calls.
ALTER FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) RENAME TO direct_delivery_tickets_before_translation;
REVOKE ALL ON FUNCTION public.direct_delivery_tickets_before_translation(uuid,text[],integer) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_delivery_ticket_list_v3(p_store_id uuid,p_statuses text[] DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH page AS(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_delivery_tickets_before_translation($1,$2,$3)) WITH ORDINALITY e),
 notes AS(SELECT j.request_id,j.source_text,jsonb_object_agg(j.target_locale,j.translated_text) FILTER(WHERE j.status='translated') translations,
 CASE WHEN bool_and(j.status='translated') THEN 'translated' WHEN bool_or(j.status='failed') THEN 'failed' ELSE 'pending' END status
 FROM public.direct_order_translation_jobs j WHERE j.source_kind='item_note' AND j.request_id IN (SELECT (value->>'request_id')::uuid FROM page) GROUP BY j.request_id,j.source_text),
 items AS(SELECT p.ordinality,jsonb_agg(i.value||jsonb_build_object('note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) ORDER BY i.ordinality) value
 FROM page p CROSS JOIN LATERAL jsonb_array_elements(p.value->'items') WITH ORDINALITY i
 LEFT JOIN notes n ON n.request_id::text=p.value->>'request_id' AND n.source_text=i.value->>'note' GROUP BY p.ordinality)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('items',COALESCE(i.value,'[]'::jsonb)) ORDER BY p.ordinality),'[]'::jsonb) FROM page p LEFT JOIN items i USING(ordinality);
$$;
REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) TO authenticated,service_role;
CREATE FUNCTION public.direct_order_retry_translation(p_store_id uuid,p_request_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE changed integer;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 AND pii_purged_at IS NULL AND support_closed_at IS NULL) THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 UPDATE public.direct_order_translation_jobs SET status='pending',attempts=0,retry_at=now(),lease_until=NULL,lease_id=NULL WHERE request_id=$2 AND status='failed';
 GET DIAGNOSTICS changed=ROW_COUNT;RETURN changed;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_retry_translation(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_retry_translation(uuid,uuid) TO authenticated,service_role;
DO $live_refresh$
BEGIN
 IF to_regprocedure('public.emit_pos_live_event()') IS NOT NULL THEN
  CREATE TRIGGER direct_order_translation_message_live AFTER UPDATE OF metadata ON public.direct_order_messages FOR EACH ROW WHEN(OLD.metadata IS DISTINCT FROM NEW.metadata) EXECUTE FUNCTION public.emit_pos_live_event('direct_order_chat');
  CREATE TRIGGER direct_order_translation_note_live AFTER UPDATE OF updated_at ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.emit_pos_live_event('direct_order_chat');
  CREATE TRIGGER direct_order_translation_kitchen_live AFTER UPDATE OF updated_at ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.emit_pos_live_event('direct_delivery_status');
 END IF;
END; $live_refresh$;
-- Clear translated PII along with its source during the existing retention run.
DO $retention$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure) INTO d;
 IF strpos(d,'SET customer_note = NULL')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_RETENTION_DRIFT'; END IF;
 d:=replace(d,'  RETURN jsonb_build_object(',E'  DELETE FROM public.direct_order_translation_jobs WHERE request_id=ANY(p_request_ids);\n  RETURN jsonb_build_object(');
 IF strpos(d,'DELETE FROM public.direct_order_translation_jobs')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_RETENTION_DRIFT'; END IF;
 EXECUTE d;
END; $retention$;
DO $schedule$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron') AND EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_net') THEN
 PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='direct-order-translation-dispatch';
 PERFORM cron.schedule('direct-order-translation-dispatch','10 seconds',$job$
 SELECT net.http_post(url:='https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/direct-order-translation-dispatcher',
 headers:=jsonb_build_object('Authorization','Bearer '||(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name IN ('cron_secret','app.settings.cron_secret') ORDER BY(name='cron_secret') DESC LIMIT 1),'Content-Type','application/json'),body:='{}'::jsonb)
 $job$);
 END IF;
EXCEPTION WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN RAISE NOTICE 'Configure direct-order translation scheduler before release';
END; $schedule$;
DO $verify$ BEGIN
 IF has_table_privilege('authenticated','public.direct_order_translation_jobs','SELECT') OR has_function_privilege('authenticated','public.claim_direct_order_translations(integer)','EXECUTE') THEN RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_PERMISSION_DRIFT'; END IF;
END; $verify$;
COMMIT;
