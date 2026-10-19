BEGIN;
CREATE FUNCTION public.can_read_procurement_document(p_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE parts text[]:=string_to_array(p_path,'/');store uuid;actor jsonb;
BEGIN
 IF parts[1] !~ '^[0-9a-fA-F-]{36}$' THEN RETURN false; END IF;
 store:=parts[1]::uuid;
 IF NOT public.can_access_inventory_workflow(store) THEN RETURN false; END IF;
 actor:=public.procurement_actor(store);
 IF parts[2]='procurement' THEN
   IF parts[3]='po' AND parts[5]='supplier' THEN RETURN true; END IF;
   IF parts[3]='pr' AND parts[5]='internal' THEN RETURN true; END IF;
 END IF;
 RETURN COALESCE((actor->>'can_view_prices')::boolean,false);
END $$;
REVOKE ALL ON FUNCTION public.can_read_procurement_document(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_read_procurement_document(text) TO authenticated;
DROP POLICY IF EXISTS inventory_purchase_document_objects_read ON storage.objects;
CREATE POLICY inventory_purchase_document_objects_read ON storage.objects FOR SELECT TO authenticated
 USING(bucket_id='inventory-purchase-documents' AND public.can_read_procurement_document(name));
-- Requests are RPC-only tables. A definer helper is needed for the storage policy.
CREATE FUNCTION public.can_write_procurement_pr_document(p_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE parts text[]:=string_to_array(p_path,'/');
BEGIN
 IF parts[1] !~ '^[0-9a-fA-F-]{36}$' OR parts[4] !~ '^[0-9a-fA-F-]{36}$' OR parts[2]<>'procurement' OR parts[3]<>'pr' OR parts[5]<>'internal' THEN RETURN false; END IF;
 RETURN public.can_create_inventory_purchase_order(parts[1]::uuid) AND EXISTS(SELECT 1 FROM public.inventory_purchase_requests WHERE id=parts[4]::uuid AND restaurant_id=parts[1]::uuid);
END $$;
REVOKE ALL ON FUNCTION public.can_write_procurement_pr_document(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_write_procurement_pr_document(text) TO authenticated;
CREATE POLICY procurement_pr_objects_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='inventory-purchase-documents' AND public.can_write_procurement_pr_document(name));
CREATE POLICY procurement_pr_objects_update ON storage.objects FOR UPDATE TO authenticated
 USING(bucket_id='inventory-purchase-documents' AND public.can_write_procurement_pr_document(name))
 WITH CHECK(bucket_id='inventory-purchase-documents' AND public.can_write_procurement_pr_document(name));
COMMIT;
