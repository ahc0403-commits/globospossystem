SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
SELECT admin_create_brand_v2('50000000-0000-4000-8000-000000000001','JeonGabok','JG','30000000-0000-4000-8000-000000000001',ARRAY['40000000-0000-4000-8000-000000000001']::uuid[]);
SELECT brand_assert(jsonb_array_length(admin_preview_store_accounts_v1('50000000-0000-4000-8000-000000000001','JGBT',ARRAY['1F','2F','3F']))=13,'preview13 accounts');
SELECT admin_create_store_onboarding_v1('60000000-0000-4000-8000-000000000001','JeonGabok Binh Thanh','address','JGBT','50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',ARRAY['1F','2F','3F']) store_id \gset
SELECT brand_assert(admin_create_store_onboarding_v1('60000000-0000-4000-8000-000000000001','JeonGabok Binh Thanh','address','jgbt','50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',ARRAY['3F','1F','2F'])=:'store_id'::uuid,'lost response idempotency');
SELECT brand_expect_error($q$SELECT admin_create_store_onboarding_v1('60000000-0000-4000-8000-000000000001','changed','address','JGBT','50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',ARRAY['1F'])$q$,'REQUEST_CONFLICT');
SELECT brand_expect_error($q$SELECT admin_set_registration_abbreviation_v1('brand','50000000-0000-4000-8000-000000000001','JH')$q$,'ABBREVIATION_ALREADY_IN_USE');
SELECT brand_assert(NOT has_function_privilege('authenticated','claim_store_onboarding_v1(uuid)','EXECUTE'),'worker inaccessible to authenticated');
RESET ROLE;
SELECT brand_assert((SELECT count(*)=1 FROM restaurants),'no duplicate store');
SELECT brand_assert((SELECT count(*)=13 FROM store_fixed_account_requirements),'requirements13');
SET ROLE service_role;
SELECT claim_store_onboarding_v1('60000000-0000-4000-8000-000000000001') claim \gset
SELECT brand_assert(claim_store_onboarding_v1('60000000-0000-4000-8000-000000000001') IS NULL,'exclusive lease');
RESET ROLE;
-- Simulate Auth API-created identities with the exact trusted ownership marker.
INSERT INTO auth.users(id,instance_id,email,is_sso_user,raw_app_meta_data,encrypted_password)
SELECT gen_random_uuid(),'00000000-0000-0000-0000-000000000000',i->>'account_code'||'@globos.world',false,jsonb_build_object('store_onboarding',jsonb_build_object('code',i->>'account_code','role',i->>'role','type',i->>'account_type','scope',i->>'scope','owner_id',i->>'owner_id')),'unchanged-fixture-hash' FROM jsonb_array_elements(:'claim'::jsonb->'items') i WHERE i->>'account_code'<>'jgbt_pos1';
-- A pre-existing Auth email without trusted ownership must never be adopted.
INSERT INTO auth.users(id,instance_id,email,is_sso_user,raw_app_meta_data,encrypted_password) VALUES(gen_random_uuid(),'00000000-0000-0000-0000-000000000000','jgbt_pos1@globos.world',false,'{}','legacy-hash');
SET ROLE service_role;
SELECT finish_store_onboarding_v1('60000000-0000-4000-8000-000000000001',(:'claim'::jsonb->>'lease_id')::uuid);
RESET ROLE;
SELECT brand_assert((SELECT count(*)=12 FROM users WHERE fixed_account_code IS NOT NULL),'untrusted Auth email rejected');
SELECT brand_assert((SELECT count(*)=3 FROM emergency_station_assignments WHERE station_type='floor'),'all 3 floors assigned');
SELECT brand_assert((SELECT count(*)=1 FROM emergency_station_assignments WHERE floor_label='3F'),'3F isolated assignment');
SELECT brand_assert(NOT EXISTS(SELECT FROM users WHERE fixed_account_code IS NOT NULL AND NOT must_change_password),'first password gate');
SELECT brand_assert((SELECT encrypted_password='legacy-hash' FROM auth.users WHERE email='jgbt_pos1@globos.world'),'existing password preserved');
-- Recovery after an Auth acknowledgment is lost: marker remains trusted.
UPDATE auth.users SET raw_app_meta_data=(SELECT jsonb_build_object('store_onboarding',jsonb_build_object('code',i->>'account_code','role',i->>'role','type',i->>'account_type','scope',i->>'scope','owner_id',i->>'owner_id')) FROM jsonb_array_elements(:'claim'::jsonb->'items') i WHERE i->>'account_code'='jgbt_pos1') WHERE email='jgbt_pos1@globos.world';
SET ROLE service_role;
SELECT claim_store_onboarding_v1('60000000-0000-4000-8000-000000000001') claim2 \gset
SELECT finish_store_onboarding_v1('60000000-0000-4000-8000-000000000001',(:'claim2'::jsonb->>'lease_id')::uuid);
RESET ROLE;
SELECT brand_assert((SELECT readiness @> '{"requester":true,"store_manager":true,"receiver":true,"accounting":false}' AND NOT office_connected FROM procurement_store_onboarding WHERE restaurant_id=:'store_id'::uuid),'actual procurement connector reports missing shared accounts');
SELECT brand_assert((SELECT status='complete' FROM store_account_onboarding_jobs),'resume completes');
SELECT brand_assert((SELECT count(*)=13 FROM users WHERE fixed_account_code IS NOT NULL),'exactly13 identities');
SET ROLE authenticated;
SELECT admin_create_store_onboarding_v1('60000000-0000-4000-8000-000000000002','Second store','address','JG02','50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',ARRAY['1F']);
RESET ROLE;
SELECT brand_assert((SELECT count(DISTINCT account_code)=1 FROM store_fixed_account_requirements WHERE scope='brand'),'BM identity shared');
-- A mutable workforce template cannot broaden the frozen master job.
UPDATE store_fixed_account_requirements SET account_type='brand_manager',role='brand_admin',scope='brand' WHERE account_code='jg02_sm1';
SET ROLE service_role;
SELECT brand_assert(claim_store_onboarding_v1('60000000-0000-4000-8000-000000000002') IS NULL,'changed role/scope blocks Auth creation');
RESET ROLE;
SELECT brand_assert((SELECT status='partial' FROM store_account_onboarding_jobs WHERE id='60000000-0000-4000-8000-000000000002'),'changed manifest requires explicit recovery');
UPDATE store_fixed_account_requirements SET account_type='store_manager',role='store_admin',scope='store' WHERE account_code='jg02_sm1';
SET ROLE authenticated;
SELECT admin_store_onboarding_status_v1('60000000-0000-4000-8000-000000000002',true);
RESET ROLE;
-- The legacy store mutation endpoint cannot redirect a queued job to another brand.
SET ROLE authenticated;
SELECT admin_create_brand_v2('50000000-0000-4000-8000-000000000099','Other brand','OT','30000000-0000-4000-8000-000000000001',ARRAY['40000000-0000-4000-8000-000000000001']::uuid[]);
RESET ROLE;
UPDATE restaurants SET brand_id='50000000-0000-4000-8000-000000000099' WHERE short_code='JG02';
SET ROLE service_role;
SELECT brand_assert(claim_store_onboarding_v1('60000000-0000-4000-8000-000000000002') IS NULL,'changed parent brand blocks account issuance');
RESET ROLE;
UPDATE restaurants SET brand_id='50000000-0000-4000-8000-000000000001' WHERE short_code='JG02';
SET ROLE authenticated;
SELECT admin_store_onboarding_status_v1('60000000-0000-4000-8000-000000000002',true);
RESET ROLE;
-- Explicit brand access is authoritative even when the legacy primary brand is unset.
UPDATE users SET brand_id=NULL,primary_store_id=NULL WHERE fixed_account_code='jg_bm1';
SET ROLE service_role;
SELECT claim_store_onboarding_v1('60000000-0000-4000-8000-000000000002') claim3 \gset
SELECT finish_store_onboarding_v1('60000000-0000-4000-8000-000000000002',(:'claim3'::jsonb->>'lease_id')::uuid);
RESET ROLE;
SELECT brand_assert((SELECT count(*)=1 FROM users WHERE fixed_account_code='jg_bm1'),'shared BM has one profile');
SELECT brand_assert((SELECT a.raw_app_meta_data->>'primary_store_id'=u.restaurant_id::text FROM users u JOIN auth.users a ON a.id=u.auth_id WHERE u.fixed_account_code='jg_bm1'),'primary store claim preserves legacy fallback');
SELECT brand_assert((SELECT count(*)=2 FROM user_store_access sa JOIN users u ON u.id=sa.user_id WHERE u.fixed_account_code='jg_bm1'),'BM gets both stores');
SELECT brand_assert((SELECT count(*)=1 FROM user_store_access sa JOIN users u ON u.id=sa.user_id WHERE u.fixed_account_code='jgbt_sm1'),'store manager remains store scoped');
SELECT brand_assert(NOT EXISTS(SELECT 1 FROM user_store_access sa JOIN users u ON u.id=sa.user_id WHERE u.fixed_account_code='jg_bm1' AND (sa.source_type<>'brand_inherited' OR sa.source_brand_access_id IS NULL)),'brand grants retain inherited source for revocation');
BEGIN;
UPDATE user_brand_access SET is_active=false WHERE user_id=(SELECT id FROM users WHERE fixed_account_code='jg_bm1');
SELECT sync_user_store_access((SELECT id FROM users WHERE fixed_account_code='jg_bm1'));
SELECT brand_assert(NOT EXISTS(SELECT 1 FROM user_store_access sa JOIN users u ON u.id=sa.user_id WHERE u.fixed_account_code='jg_bm1' AND sa.is_active),'actual canonical sync revokes inherited store grants');
SELECT brand_assert((SELECT count(*)=1 FROM user_store_access sa JOIN users u ON u.id=sa.user_id WHERE u.fixed_account_code='jgbt_sm1' AND sa.is_active AND sa.source_type='direct'),'brand revocation preserves unrelated direct store grant');
ROLLBACK;
-- Initial brand abbreviation setup must work for legacy brands with issued IDs.
UPDATE brands SET short_code=NULL WHERE id='50000000-0000-4000-8000-000000000001';
SET ROLE authenticated;
SELECT admin_set_registration_abbreviation_v1('brand','50000000-0000-4000-8000-000000000001','JG');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',false);
SET ROLE authenticated;
SELECT brand_expect_error($q$SELECT admin_store_onboarding_status_v1('60000000-0000-4000-8000-000000000001')$q$,'BRAND_ADMIN_FORBIDDEN');
RESET ROLE;
SELECT 'STORE_ACCOUNT_ONBOARDING=PASS';
