\set ON_ERROR_STOP on
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
SELECT brand_assert(jsonb_array_length(admin_brand_groups_v1())=1,'groups available');
SELECT admin_create_brand_v1('50000000-0000-4000-8000-000000000001','Independent brand',' NEW_BRAND ',
  '30000000-0000-4000-8000-000000000001');
RESET ROLE;
SELECT brand_assert((SELECT count(*)=1 AND min(code)='new_brand' FROM brands),'brand created without store');
SELECT brand_assert(NOT EXISTS(SELECT FROM restaurants),'no implicit store');
SELECT brand_assert(NOT EXISTS(SELECT FROM tax_entity_brands),'legal entity optional');
SET ROLE authenticated;
SELECT brand_assert((admin_list_brands_v1()->'items'->0->>'store_count')::int=0,'zero-store brand visible');
-- Same request is safe to retry, including after a lost response.
SELECT admin_create_brand_v1('50000000-0000-4000-8000-000000000001','Independent brand','new_brand',
  '30000000-0000-4000-8000-000000000001');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1('50000000-0000-4000-8000-000000000001','Changed','new_brand',
 '30000000-0000-4000-8000-000000000001')$q$,'BRAND_REQUEST_CONFLICT');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'Duplicate','NEW_BRAND',
 '30000000-0000-4000-8000-000000000001')$q$,'BRAND_CODE_EXISTS');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'Missing group','missing_group',NULL)$q$,'BRAND_GROUP_REQUIRED');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'','empty_name','30000000-0000-4000-8000-000000000001')$q$,'BRAND_NAME_INVALID');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'Bad code','invalid code','30000000-0000-4000-8000-000000000001')$q$,'BRAND_CODE_INVALID');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'Atomic','atomic_brand',
 '30000000-0000-4000-8000-000000000001',ARRAY['49999999-0000-4000-8000-000000000001']::uuid[])$q$,'BRAND_LEGAL_ENTITY_INVALID');
SELECT brand_expect_error($q$SELECT admin_create_restaurant_v2('Unlinked','unlinked','standard',
 '40000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001')$q$,'RESTAURANT_TAX_ENTITY_BRAND_INVALID');
SELECT admin_link_brand_tax_entities_v1('50000000-0000-4000-8000-000000000001',
 ARRAY['40000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000002']::uuid[]);
SELECT admin_link_brand_tax_entities_v1('50000000-0000-4000-8000-000000000001',
 ARRAY['40000000-0000-4000-8000-000000000001']::uuid[]);
SELECT brand_assert(jsonb_array_length(admin_create_brand_v1(
 '50000000-0000-4000-8000-000000000001','Independent brand','new_brand',
 '30000000-0000-4000-8000-000000000001')->'tax_entity_ids')=2,'creation replay returns current links');
SELECT brand_expect_error($q$SELECT admin_link_brand_tax_entities_v1('50000000-0000-4000-8000-000000000001',
 ARRAY['49999999-0000-4000-8000-000000000001']::uuid[])$q$,'BRAND_LEGAL_ENTITY_INVALID');
SELECT admin_create_restaurant_v2('Internal store','internal-store','standard',
 '40000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001');
SELECT admin_create_restaurant_v2('External store','external-store','standard',
 '40000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001');
SELECT brand_assert((admin_list_brands_v1()->'items'->0->>'store_count')::int=2,'links do not multiply store count');
SELECT brand_assert(jsonb_array_length(admin_list_brands_v1()->'items'->0->'tax_entity_ids')=2,'multiple entities preserved');
SELECT brand_expect_error($q$INSERT INTO brands(name,code,brand_master_id) VALUES('Bypass','bypass','30000000-0000-4000-8000-000000000001')$q$,'row-level security');
RESET ROLE;
SELECT brand_assert((SELECT count(*)=1 FROM audit_logs WHERE action='admin_create_brand_v1'),'retry does not duplicate creation audit');
SELECT brand_assert((SELECT count(*)=1 FROM audit_logs WHERE action='admin_link_brand_tax_entities_v1'),'link retry does not duplicate audit');
SELECT brand_assert((SELECT count(*)=1 FROM brands),'failed creation is atomic');
SELECT brand_assert((SELECT bool_and(store_type=CASE WHEN slug='internal-store' THEN 'direct' ELSE 'external' END) FROM restaurants),'Office store type preserved');
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',false);
SET ROLE authenticated;
SELECT brand_expect_error('SELECT admin_brand_groups_v1()','BRAND_ADMIN_FORBIDDEN');
SELECT brand_expect_error('SELECT admin_list_brands_v1()','BRAND_ADMIN_FORBIDDEN');
SELECT brand_expect_error($q$SELECT admin_create_brand_v1(gen_random_uuid(),'Unauthorized','unauthorized','30000000-0000-4000-8000-000000000001')$q$,'BRAND_ADMIN_FORBIDDEN');
SELECT brand_expect_error($q$SELECT admin_link_brand_tax_entities_v1('50000000-0000-4000-8000-000000000001','{}')$q$,'BRAND_ADMIN_FORBIDDEN');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',false);
SET ROLE authenticated;
SELECT brand_expect_error('SELECT admin_list_brands_v1()','BRAND_ADMIN_FORBIDDEN');
RESET ROLE;
SET ROLE anon;
-- Assert the effective ACL directly. This Supabase image crashes when an anon
-- permission error is caught inside a nested dynamic PL/pgSQL exception block.
SELECT brand_assert(NOT has_function_privilege(current_user,'admin_brand_groups_v1()','EXECUTE'),'anon cannot load groups');
SELECT brand_assert(NOT has_function_privilege(current_user,'admin_list_brands_v1(text,text,uuid,integer)','EXECUTE'),'anon cannot list brands');
SELECT brand_assert(NOT has_function_privilege(current_user,'admin_create_brand_v1(uuid,text,text,uuid,uuid[])','EXECUTE'),'anon cannot create');
SELECT brand_assert(NOT has_function_privilege(current_user,'admin_link_brand_tax_entities_v1(uuid,uuid[])','EXECUTE'),'anon cannot link');
RESET ROLE;
-- Scale: same-name cursor ties and >1 page, with many stores per brand.
INSERT INTO brands(id,name,code,company_id,brand_master_id)
SELECT md5('brand'||n)::uuid,'Scale '||lpad((n/3)::text,4,'0'),'scale_'||n,
 '20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001' FROM generate_series(1,1000) n;
INSERT INTO tax_entity_brands SELECT '40000000-0000-4000-8000-000000000001',id,NULL FROM brands WHERE code LIKE 'scale_%';
INSERT INTO restaurants(id,name,slug,operation_mode,tax_entity_id,brand_id,store_type,is_active,created_at)
SELECT gen_random_uuid(),'Scale store',b.code||'-'||n,'standard','40000000-0000-4000-8000-000000000001',b.id,'direct',true,now()
FROM brands b CROSS JOIN generate_series(1,10) n WHERE b.code LIKE 'scale_%';
ANALYZE public.brands;
ANALYZE public.tax_entity_brands;
ANALYZE public.restaurants;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $$ DECLARE result jsonb; last_row jsonb; seen uuid[]:='{}'; row jsonb; pages int:=0;
BEGIN
 LOOP
  result:=admin_list_brands_v1('scale',last_row->>'name',(last_row->>'id')::uuid);
  pages:=pages+1;
  PERFORM brand_assert(jsonb_array_length(result->'items')<=50,'bounded page');
  FOR row IN SELECT value FROM jsonb_array_elements(result->'items') LOOP
   PERFORM brand_assert(NOT (row->>'id')::uuid=ANY(seen),'cursor does not duplicate ties');
   PERFORM brand_assert((row->>'store_count')::int=10,'set-based counts');
   seen:=array_append(seen,(row->>'id')::uuid); last_row:=row;
  END LOOP;
  EXIT WHEN NOT (result->>'has_more')::boolean;
  PERFORM brand_assert(pages<30,'cursor terminates');
 END LOOP;
 PERFORM brand_assert(cardinality(seen)=1000 AND pages=20,'1000 brands in 20 pages');
END $$;
\timing on
SELECT jsonb_array_length(result->'items') page_rows,octet_length(result::text) response_bytes
FROM (SELECT admin_list_brands_v1('scale') result) measured;
EXPLAIN(ANALYZE,BUFFERS) SELECT admin_list_brands_v1('scale');
\timing off
RESET ROLE;
SELECT 'INDEPENDENT_BRAND_SQL=PASS';
