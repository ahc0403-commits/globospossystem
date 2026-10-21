-- Isolated upgrade fixture for the CURRENT production schema, no production data.
\set ON_ERROR_STOP on
BEGIN;
-- The PostgreSQL fixture image ships an older Auth table, without GoTrue migrations.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email_confirmed_at timestamptz,
 ADD COLUMN IF NOT EXISTS banned_until timestamptz;
CREATE SCHEMA IF NOT EXISTS realtime;
CREATE TABLE realtime.kds_lab_messages(topic text, payload jsonb);
CREATE FUNCTION realtime.send(payload jsonb,event text,topic text,private boolean)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=realtime,pg_catalog AS $$ INSERT INTO realtime.kds_lab_messages VALUES(topic,payload); $$;
GRANT USAGE ON SCHEMA realtime TO postgres;
INSERT INTO public.companies(id,name) VALUES ('91000000-0000-4000-8000-000000000001','KDS lab company');
INSERT INTO public.brand_master(id,company_id,name,type)
VALUES ('91000000-0000-4000-8000-000000000002','91000000-0000-4000-8000-000000000001','KDS lab','internal');
INSERT INTO public.brands(id,brand_master_id,code,name)
VALUES ('91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000002','kds_lab','KDS lab');
INSERT INTO public.tax_entity(id,tax_code,name,owner_type)
VALUES ('91000000-0000-4000-8000-000000000004','9100000000','KDS lab entity','internal');
INSERT INTO public.tax_entity_brands(tax_entity_id,brand_id)
VALUES ('91000000-0000-4000-8000-000000000004','91000000-0000-4000-8000-000000000003');
INSERT INTO public.restaurants(id,name,brand_id,tax_entity_id) VALUES
('273b057e-3b69-46e3-93c1-6194c2802849','JeonGabok Binh Thanh','91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000004'),
('8bc9eef5-dcd5-46b1-b931-23f77132322c','BunsikClub Binh Thanh','91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000004');
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
VALUES('92000000-0000-4000-8000-000000000099','operating-lab-admin@internal.invalid',
 '00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name)
VALUES('93000000-0000-4000-8000-000000000099','92000000-0000-4000-8000-000000000099',
 '273b057e-3b69-46e3-93c1-6194c2802849','super_admin','Operating fixture admin');
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
INSERT INTO public.restaurant_settings(restaurant_id,fulfillment_mode)
SELECT id,'paperless' FROM public.restaurants;
INSERT INTO public.emergency_fulfillment_sessions(restaurant_id,reason)
SELECT id,'Isolated direct floor regression' FROM public.restaurants;
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
SELECT ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'kds-lab-'||n||'@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now()
FROM generate_series(1,10) n;
INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name,fixed_account_code,account_type,is_active)
SELECT ('93000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE WHEN n<=5 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid ELSE '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid END,
 CASE WHEN n IN (1,6) THEN 'kitchen' ELSE 'emergency_station' END,
 'KDS lab '||n,
 CASE n WHEN 1 THEN 'jgbt_kit' WHEN 2 THEN 'jgbt_tray1' WHEN 3 THEN 'jgbt_floor_1f'
 WHEN 4 THEN 'jgbt_floor_2f' WHEN 5 THEN 'jgbt_floor_3f' WHEN 6 THEN 'bt_kit' WHEN 7 THEN 'bt_tray1'
 WHEN 8 THEN 'bt_floor_1f' WHEN 9 THEN 'bt_floor_2f' ELSE 'bt_floor_3f' END,
 CASE WHEN n IN (1,6) THEN 'device_kitchen' ELSE 'device_emergency_station' END,n<>2
FROM generate_series(1,10) n;
INSERT INTO public.user_store_access(user_id,store_id,is_primary,is_active,source_type)
SELECT id,restaurant_id,true,true,'direct' FROM public.users;
INSERT INTO public.store_fixed_account_requirements(store_id,account_code,account_type,role,display_name,scope,provisioned_user_id)
SELECT restaurant_id,fixed_account_code,account_type,role,full_name,'store',id FROM public.users WHERE fixed_account_code IS NOT NULL;
INSERT INTO public.kds_realtime_rollouts(restaurant_id,mode)
SELECT id,'active' FROM public.restaurants;
COMMIT;
