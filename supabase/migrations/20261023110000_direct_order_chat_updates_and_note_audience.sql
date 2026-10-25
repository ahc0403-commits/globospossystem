-- Small authenticated change checks and explicit private/preparation audiences.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

ALTER TABLE public.direct_order_requests ADD COLUMN chat_revision bigint NOT NULL DEFAULT 0;

-- A batch of messages updates each affected request once. No history scans or
-- message bodies are sent through the update-check endpoint.
CREATE FUNCTION public.direct_order_bump_chat_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 UPDATE public.direct_order_requests r SET chat_revision=r.chat_revision+1
 FROM (SELECT DISTINCT request_id FROM chat_changes) changed
 WHERE r.id=changed.request_id;
 RETURN NULL;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_bump_chat_revision() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_chat_revision_insert AFTER INSERT ON public.direct_order_messages
 REFERENCING NEW TABLE AS chat_changes FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_bump_chat_revision();
CREATE TRIGGER direct_order_chat_revision_update AFTER UPDATE ON public.direct_order_messages
 REFERENCING NEW TABLE AS chat_changes FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_bump_chat_revision();
CREATE TRIGGER direct_order_chat_revision_delete AFTER DELETE ON public.direct_order_messages
 REFERENCING OLD TABLE AS chat_changes FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_bump_chat_revision();

CREATE FUNCTION public.direct_order_public_updates(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; revision bigint; updated timestamptz; purged timestamptz;
BEGIN
 s:=public.direct_order_validate_session($1,$2);
 SELECT chat_revision,updated_at,pii_purged_at INTO revision,updated,purged
 FROM public.direct_order_requests WHERE id=$3 AND session_id=s.id AND restaurant_id=s.restaurant_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF purged IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 IF NOT public.direct_order_consume_public_rate(md5('chat-updates:'||s.id::text||':'||$3::text),60,60) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_CHAT_RATE_LIMITED';
 END IF;
 RETURN jsonb_build_object('revision',revision::text||':'||updated::text);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_updates(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_updates(uuid,text,uuid) TO service_role;

ALTER TABLE public.direct_order_customer_requirements
 DROP CONSTRAINT direct_order_customer_requirements_print_scope_check,
 ADD CONSTRAINT direct_order_customer_requirements_print_scope_check
  CHECK(print_scope IN('cashier','preparation','delivery','both')),
 ALTER COLUMN print_scope SET DEFAULT 'cashier';
-- Whole-order notes were implicitly sent everywhere. Preserve explicit kitchen
-- or delivery scopes and every item-level cooking request.
WITH changed AS (
 UPDATE public.direct_order_customer_requirements
 SET print_scope='cashier',version=version+1,updated_at=clock_timestamp()
 WHERE source_kind='order' AND print_scope='both' RETURNING request_id
)
UPDATE public.direct_order_requests r SET updated_at=clock_timestamp()
 FROM (SELECT DISTINCT request_id FROM changed) q WHERE r.id=q.request_id;

DO $audience$
DECLARE definition text; needle text; signature text;
BEGIN
 signature:='public.direct_order_capture_requirements()';
 definition:=pg_get_functiondef(signature::regprocedure);
 needle:='request_text,source_locale)';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT'; END IF;
 definition:=replace(definition,needle,'request_text,source_locale,print_scope)');
 definition:=replace(definition,$old$'order',id,btrim(customer_note),locale FROM$old$,
  $new$'order',id,btrim(customer_note),locale,'cashier' FROM$new$);
 definition:=replace(definition,'source_locale,item_label_vi)','source_locale,item_label_vi,print_scope)');
 definition:=replace(definition,$old$COALESCE(NULLIF(btrim(i.name_vi),''),'Món '||(i.sort_order+1))$old$,
  $new$COALESCE(NULLIF(btrim(i.name_vi),''),'Món '||(i.sort_order+1)),'preparation'$new$);
 -- A source edit restores its declared audience together with its agreement.
 definition:=replace(definition,'SET request_text=EXCLUDED.request_text,',
  'SET request_text=EXCLUDED.request_text,print_scope=EXCLUDED.print_scope,');
 IF strpos(definition,'''cashier'' FROM')=0 OR strpos(definition,'''preparation''')=0 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT';
 END IF;
 EXECUTE definition;

 signature:='public.direct_order_staff_reply_requirement(uuid,uuid,uuid,integer,uuid,text,text,boolean,text,text,text)';
 definition:=pg_get_functiondef(signature::regprocedure);
 needle:=$old$NOT IN ('preparation','delivery','both')$old$;
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT'; END IF;
 definition:=replace(definition,needle,$new$NOT IN ('cashier','preparation','delivery','both')$new$);
 definition:=replace(definition,'OR $8 IS NULL',
  'OR $8 IS NULL OR length(COALESCE($9,''''))>2000 OR length(COALESCE($10,''''))>2000');
 definition:=replace(definition,$old$OR length(COALESCE(btrim($9),'')) NOT BETWEEN 1 AND 2000$old$,
  $new$OR ($11<>'cashier' AND (length(COALESCE(btrim($9),'')) NOT BETWEEN 1 AND 2000$new$);
 needle:=$old$OR $10 !~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$' THEN$old$;
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT'; END IF;
 definition:=replace(definition,needle,
  $new$OR $10 !~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$')) THEN$new$);
 EXECUTE definition;

 signature:='public.direct_order_requirement_print_snapshot(uuid,text)';
 definition:=pg_get_functiondef(signature::regprocedure);
 needle:=$old$AND ($2='receipt' OR print_scope='both' OR print_scope=$2)$old$;
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(definition,needle,$new$AND print_scope<>'cashier' AND ($2='receipt' OR print_scope='both' OR print_scope=$2)$new$);

 signature:='public.direct_order_emit_requirement_addendum(uuid)';
 definition:=pg_get_functiondef(signature::regprocedure);
 needle:='IF NOT FOUND THEN RETURN; END IF;';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_NOTE_AUDIENCE_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(definition,needle,'IF NOT FOUND OR q.print_scope=''cashier'' THEN RETURN; END IF;');
END;
$audience$;

DO $$ BEGIN
 IF has_function_privilege('anon','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE')
 OR (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.direct_order_messages'::regclass
  AND tgname IN('direct_order_chat_revision_insert','direct_order_chat_revision_update','direct_order_chat_revision_delete'))<>3
 OR EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE source_kind='order' AND print_scope='both') THEN
  RAISE EXCEPTION 'DIRECT_ORDER_CHAT_AUDIENCE_VERIFICATION_FAILED';
 END IF;
END $$;
COMMIT;
