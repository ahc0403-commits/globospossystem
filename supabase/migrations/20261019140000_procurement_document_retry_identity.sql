BEGIN;
CREATE OR REPLACE FUNCTION public.record_procurement_document(p_store_id uuid,p_kind text,p_record_id uuid,p_audience text,p_source_hash text,p_storage_path text,p_sha256 text,p_size_bytes integer,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; source jsonb; result jsonb; existing public.procurement_document_exports%rowtype;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT (COALESCE((actor->>'can_create')::boolean,false) OR COALESCE((actor->>'can_office_approve')::boolean,false)) THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_FORBIDDEN'; END IF;
 -- Lock the source so a concurrent commercial change cannot mark an obsolete export ready.
 IF p_kind='po' THEN PERFORM 1 FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
 ELSE PERFORM 1 FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE; END IF;
 source:=public.procurement_document_data(p_store_id,p_kind,p_record_id,p_audience,p_office_actor);
 IF source->>'source_hash' IS DISTINCT FROM p_source_hash THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_SOURCE_CHANGED'; END IF;
 IF p_storage_path IS DISTINCT FROM p_store_id||'/procurement/'||p_kind||'/'||p_record_id||'/'||p_audience||'/'||p_source_hash||'/'||p_sha256||'.pdf' THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_PATH_INVALID'; END IF;
 IF p_size_bytes NOT BETWEEN 1 AND 5242880 OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='inventory-purchase-documents' AND name=p_storage_path AND COALESCE((metadata->>'size')::integer,0)=p_size_bytes) THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_FILE_REQUIRED'; END IF;
 -- The source is locked and its hash/file verified before a replay is read.
 -- A dropped HTTP response must not create another document-generated event.
 SELECT * INTO existing FROM public.procurement_document_exports
 WHERE record_id=p_record_id AND kind=p_kind AND audience=p_audience
   AND source_hash=p_source_hash AND sha256=p_sha256;
 IF FOUND AND existing.status='ready' THEN
   RETURN to_jsonb(existing)||jsonb_build_object('replayed',true);
 END IF;
 UPDATE public.procurement_document_exports SET status='superseded' WHERE record_id=p_record_id AND kind=p_kind AND audience=p_audience AND source_hash<>p_source_hash;
 INSERT INTO public.procurement_document_exports(restaurant_id,record_id,kind,audience,source_hash,storage_path,sha256,size_bytes,generated_actor)
 VALUES(p_store_id,p_record_id,p_kind,p_audience,p_source_hash,p_storage_path,p_sha256,p_size_bytes,actor)
 ON CONFLICT(record_id,kind,audience,source_hash,sha256) DO UPDATE SET status='ready'
 RETURNING to_jsonb(procurement_document_exports) INTO result;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,next_state) VALUES(p_store_id,p_record_id,'document_generated',actor,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb) TO authenticated,service_role;
COMMIT;
