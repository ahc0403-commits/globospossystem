-- Real schema, real onboarding worker reconciliation and real KDS mutations.
BEGIN;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
UPDATE public.brands SET short_code='LAB' WHERE id='91000000-0000-4000-8000-000000000003';
DO $$ DECLARE
 request uuid:=gen_random_uuid(); shop uuid; pickup uuid; multi uuid; input jsonb; preview jsonb; lease jsonb; result jsonb;
 brand uuid:='91000000-0000-4000-8000-000000000003'; entity uuid:='91000000-0000-4000-8000-000000000004';
 kit uuid; hall uuid; tab uuid; menu uuid; ord public.orders; line uuid; item uuid; queue uuid; allocation jsonb; code text; started timestamptz:=clock_timestamp(); other_brand uuid:=gen_random_uuid(); other_entity uuid:=gen_random_uuid(); other_shop uuid; other_request uuid:=gen_random_uuid(); transfer uuid:=gen_random_uuid(); revision bigint; old_manager uuid;
BEGIN
 input:=jsonb_build_object('name','Single floor restaurant','brand',brand,'entity',entity);
 preview:=public.admin_preview_store_registration_v1(request,brand);
 code:=preview->>'code';
 ASSERT code ~ '^ST[0-9]{4}$';
 ASSERT preview->'config'->'areas'->0->>'physical_floor' IS NULL;
 ASSERT jsonb_array_length(preview->'accounts')=6,'unexpected unnecessary devices';
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(preview->'accounts')a WHERE a->>'account_code' ~ 'tray|floor_|_order$|_print$');
 ASSERT public.admin_preview_store_registration_v1(request,brand)->>'code'=code;
 shop:=public.admin_register_store_v1(request,input);
 ASSERT public.admin_register_store_v1(request,input)=shop,'retry duplicated store';
 ASSERT (SELECT count(*)=1 FROM store_account_onboarding_jobs WHERE id=request);
 ASSERT (SELECT count(*)=1 FROM store_service_areas WHERE restaurant_id=shop AND stored_code='HALL' AND physical_floor IS NULL);
 BEGIN PERFORM public.admin_register_store_v1(request,input||'{"name":"changed"}'); RAISE EXCEPTION 'changed replay accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='REQUEST_CONFLICT',SQLERRM; END;
 BEGIN PERFORM public.admin_reserve_store_code_v1(gen_random_uuid(),code); RAISE EXCEPTION 'duplicate code accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='ABBREVIATION_EXISTS',SQLERRM; END;

 lease:=public.claim_store_onboarding_v1(request);
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at,raw_app_meta_data)
 SELECT gen_random_uuid(),a->>'account_code'||'@globos.world','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),
 jsonb_build_object('store_onboarding',jsonb_build_object('code',a->>'account_code','role',a->>'role','type',a->>'account_type','scope',a->>'scope','owner_id',a->>'owner_id'))
 FROM jsonb_array_elements(lease->'items')a WHERE NOT (a->>'auth_exists')::boolean;
 result:=public.finish_store_onboarding_v1(request,(lease->>'lease_id')::uuid);
 ASSERT result->>'status'='complete',result::text;
 SELECT u.auth_id INTO kit FROM users u JOIN emergency_station_assignments a ON a.user_id=u.id WHERE a.restaurant_id=shop AND a.station_type='kitchen';
 SELECT u.auth_id INTO hall FROM users u JOIN emergency_station_assignments a ON a.user_id=u.id WHERE a.restaurant_id=shop AND a.station_type='floor' AND a.floor_label='HALL';
 ASSERT kit IS NOT NULL AND hall IS NOT NULL,'explicit station assignment missing';

 INSERT INTO tax_entity(id,tax_code,name,owner_type) VALUES(other_entity,'TRANSFER-'||other_entity,'New legal owner','internal');
 INSERT INTO brands(id,code,name,brand_master_id,short_code) SELECT other_brand,'transfer-'||other_brand,'New brand',brand_master_id,'NEW' FROM brands WHERE id=brand;
 INSERT INTO tax_entity_brands(tax_entity_id,brand_id) VALUES(other_entity,other_brand);
 other_shop:=admin_register_store_v1(other_request,jsonb_build_object('name','Destination brand branch','brand',other_brand,'entity',other_entity));
 lease:=claim_store_onboarding_v1(other_request);
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at,raw_app_meta_data)
 SELECT gen_random_uuid(),a->>'account_code'||'@globos.world','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),
 jsonb_build_object('store_onboarding',jsonb_build_object('code',a->>'account_code','role',a->>'role','type',a->>'account_type','scope',a->>'scope','owner_id',a->>'owner_id'))
 FROM jsonb_array_elements(lease->'items')a WHERE NOT (a->>'auth_exists')::boolean;
 PERFORM finish_store_onboarding_v1(other_request,(lease->>'lease_id')::uuid);
 SELECT provisioned_user_id INTO old_manager FROM store_fixed_account_requirements WHERE store_id=shop AND scope='brand' LIMIT 1;
 BEGIN UPDATE restaurants SET brand_id=other_brand,tax_entity_id=other_entity WHERE id=shop; RAISE EXCEPTION 'raw scope changed'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_REGISTERED_IDENTITY_FROZEN',SQLERRM; END;
 BEGIN PERFORM admin_transfer_store_identity_v1(transfer,shop,1,other_brand,other_entity,'{"reason":"Explicit legal transfer","scope_review":"Account access reviewed"}'); RAISE EXCEPTION 'open store transferred'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_TRANSFER_REQUIRES_CLOSED',SQLERRM; END;
 PERFORM admin_close_store(shop,'Close before explicit legal transfer');
 SELECT l.revision INTO revision FROM store_lifecycle l WHERE restaurant_id=shop;
 PERFORM admin_transfer_store_identity_v1(transfer,shop,revision,other_brand,other_entity,'{"reason":"Explicit legal transfer","scope_review":"Account access reviewed"}');
 PERFORM admin_transfer_store_identity_v1(transfer,shop,revision,other_brand,other_entity,'{"reason":"Explicit legal transfer","scope_review":"Account access reviewed"}');
 ASSERT (SELECT count(*)=1 FROM store_identity_transfers WHERE id=transfer);
 ASSERT (SELECT brand_id=other_brand AND tax_entity_id=other_entity AND short_code=code AND NOT is_active FROM restaurants WHERE id=shop);
 ASSERT EXISTS(SELECT 1 FROM store_tax_entity_history WHERE store_id=shop AND tax_entity_id=entity AND effective_to IS NOT NULL);
 ASSERT EXISTS(SELECT 1 FROM store_tax_entity_history WHERE store_id=shop AND tax_entity_id=other_entity AND effective_to IS NULL);
 ASSERT NOT EXISTS(SELECT 1 FROM user_store_access WHERE store_id=shop AND is_active);
 ASSERT NOT EXISTS(SELECT 1 FROM store_fixed_account_requirements WHERE store_id=shop AND scope='brand' AND provisioned_user_id=old_manager);
 ASSERT (SELECT brand_id=brand FROM users WHERE id=old_manager),'shared manager moved from previous brand';
 ASSERT jsonb_array_length(store_procurement_readiness_v1(ARRAY[shop,other_shop]))=2;
END $$;
SELECT 'STORE_TRANSFER=PASS common guard, closed-only, retry, history, old scope revoked, destination brand account reused';
ROLLBACK;
