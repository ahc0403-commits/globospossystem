CREATE OR REPLACE FUNCTION public.connect_procurement_pos_stores(p_stores jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'core', 'system', 'auth'
AS $function$
DECLARE result jsonb;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required'; END IF;
 IF jsonb_typeof(p_stores) IS DISTINCT FROM 'array' OR jsonb_array_length(p_stores)>100 THEN RAISE EXCEPTION 'PROCUREMENT_BATCH_LIMIT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_stores) AS x(id uuid,name text,brand_id uuid,tax_entity_id uuid) WHERE id IS NULL OR brand_id IS NULL OR tax_entity_id IS NULL OR NULLIF(btrim(name),'') IS NULL)
 THEN RAISE EXCEPTION 'PROCUREMENT_STORE_SCOPE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_stores) AS x(id uuid,brand_id uuid,tax_entity_id uuid) JOIN ops.stores s ON s.pos_store_id=x.id
 WHERE s.brand_id<>x.brand_id OR s.pos_tax_entity_id IS NOT NULL AND s.pos_tax_entity_id<>x.tax_entity_id::text)
 THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_MAPPING_CONFLICT'; END IF;
 -- Bootstrap only an existing, approved POS-store mapping from verified POS metadata.
 UPDATE ops.stores s SET pos_tax_entity_id=x.tax_entity_id::text
 FROM jsonb_to_recordset(p_stores) AS x(id uuid,brand_id uuid,tax_entity_id uuid)
 WHERE s.pos_store_id=x.id AND s.brand_id=x.brand_id AND s.pos_tax_entity_id IS NULL;
 WITH bindings AS MATERIALIZED(SELECT brand_id,pos_tax_entity_id,min(legal_entity_id::text)::uuid legal_entity_id
  FROM ops.stores WHERE pos_store_id IS NOT NULL AND pos_tax_entity_id IS NOT NULL AND legal_entity_id IS NOT NULL
  GROUP BY brand_id,pos_tax_entity_id HAVING count(DISTINCT legal_entity_id)=1)
 INSERT INTO ops.stores(name,brand_id,status,pos_store_id,pos_store_mapped_at,legal_entity_id,pos_tax_entity_id)
 SELECT x.name,x.brand_id,'active',x.id,now(),b.legal_entity_id,x.tax_entity_id::text
 FROM jsonb_to_recordset(p_stores) AS x(id uuid,name text,brand_id uuid,tax_entity_id uuid)
 JOIN bindings b ON b.brand_id=x.brand_id AND b.pos_tax_entity_id=x.tax_entity_id::text
 ON CONFLICT(pos_store_id) WHERE pos_store_id IS NOT NULL DO NOTHING;
 WITH incoming AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(p_stores) AS x(id uuid,name text,brand_id uuid,tax_entity_id uuid)),
 fixed AS MATERIALIZED(SELECT p.auth_id,COALESCE(NULLIF(p.display_name,''),au.email) display_name,g.domain,jsonb_agg(g.id ORDER BY g.id) grant_ids,max(COALESCE(g.valid_until,'infinity'::timestamptz)) valid_until
  FROM public.office_user_profiles p JOIN auth.users au ON au.id=p.auth_id
  JOIN core.office_access_grants g ON g.user_profile_id=p.id
  WHERE p.is_active AND (au.banned_until IS NULL OR au.banned_until<=now()) AND p.permission_model_version='v2' AND g.is_active AND g.revoked_at IS NULL AND g.valid_from<=now() AND (g.valid_until IS NULL OR g.valid_until>now())
  AND g.scope_level='group' AND ((g.domain='purchase' AND g.action='approve' AND p.domain_authorities @> '[{"domain":"purchase"}]')
   OR (g.domain='finance' AND g.action='view' AND p.domain_authorities @> '[{"domain":"finance"}]'))
  GROUP BY p.auth_id,p.display_name,au.email,g.domain),
 linked AS MATERIALIZED(SELECT x.*,s.id office_store_id,s.legal_entity_id FROM incoming x LEFT JOIN ops.stores s ON s.pos_store_id=x.id AND s.brand_id=x.brand_id AND s.pos_tax_entity_id=x.tax_entity_id::text),
 principals AS(SELECT COALESCE(jsonb_agg(jsonb_build_object('system','office','subject_id',auth_id,'stage',CASE domain WHEN 'purchase' THEN 'purchase' ELSE 'finance' END,'display_name',display_name,'native_scope_confirmed',true,'grant_ids',grant_ids,'valid_until',valid_until) ORDER BY auth_id,domain),'[]') rows FROM fixed)
 SELECT jsonb_build_object('connected',COALESCE(jsonb_agg(to_jsonb(l)||jsonb_build_object('principals',p.rows)) FILTER(WHERE l.office_store_id IS NOT NULL),'[]'),
  'blocked',COALESCE(jsonb_agg(jsonb_build_object('id',l.id,'reason','PROCUREMENT_OFFICE_ENTITY_MAPPING_REQUIRED')) FILTER(WHERE l.office_store_id IS NULL),'[]')) INTO result
 FROM linked l CROSS JOIN principals p;
 RETURN result;
END $function$

