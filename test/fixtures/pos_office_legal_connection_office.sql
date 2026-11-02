CREATE SCHEMA auth;
CREATE SCHEMA core;
CREATE SCHEMA ops;
CREATE SCHEMA accounting;
CREATE SCHEMA system;
CREATE TABLE auth.users(id uuid PRIMARY KEY,email text DEFAULT 'synthetic@example.test',banned_until timestamptz);
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT current_setting('request.jwt.claim.role',true) $$;
CREATE TYPE core.account_status AS ENUM('active','inactive');
CREATE TABLE public.office_user_profiles(id uuid PRIMARY KEY,auth_id uuid UNIQUE REFERENCES auth.users,
  is_active boolean,is_suspended boolean,credential_state text,account_level text,permission_model_version text,
  display_name text DEFAULT 'Fixture',domain_authorities jsonb DEFAULT '[{"domain":"purchase"},{"domain":"finance"}]');
CREATE TABLE core.office_access_grants(user_profile_id uuid REFERENCES public.office_user_profiles,
  domain text,action text,scope_level text,is_active boolean,revoked_at timestamptz,valid_from timestamptz,valid_until timestamptz,
  id uuid DEFAULT gen_random_uuid());
CREATE TABLE accounting.legal_entities(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),code text UNIQUE NOT NULL,
  display_name text NOT NULL,country_code text,registration_no text,is_active boolean DEFAULT true,
  deleted_at timestamptz,created_by uuid REFERENCES auth.users);
CREATE TABLE ops.brands(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text,status core.account_status,pos_brand_id uuid);
CREATE UNIQUE INDEX ops_brands_pos_brand_unique ON ops.brands(pos_brand_id) WHERE pos_brand_id IS NOT NULL;
CREATE TABLE ops.legal_entity_brands(legal_entity_id uuid REFERENCES accounting.legal_entities,brand_id uuid REFERENCES ops.brands,
  UNIQUE(legal_entity_id,brand_id));
CREATE TABLE ops.stores(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text,status core.account_status,
  brand_id uuid REFERENCES ops.brands,legal_entity_id uuid REFERENCES accounting.legal_entities,pos_store_id uuid UNIQUE,pos_tax_entity_id text,
  pos_store_mapped_at timestamptz);
CREATE TABLE system.audit_log(actor_id uuid,action text,entity_type text,detail jsonb);
INSERT INTO auth.users(id) VALUES('20000000-0000-4000-8000-000000000001'),('20000000-0000-4000-8000-000000000002');
INSERT INTO public.office_user_profiles(id,auth_id,is_active,is_suspended,credential_state,account_level,permission_model_version) VALUES
 ('21000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',true,false,'active','super_admin','v2'),
 ('21000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002',true,false,'active','staff','v2');
INSERT INTO core.office_access_grants(user_profile_id,domain,action,scope_level,is_active,revoked_at,valid_from,valid_until) VALUES
 ('21000000-0000-4000-8000-000000000001','system','admin','group',true,null,now()-interval '1 hour',null),
 ('21000000-0000-4000-8000-000000000001','purchase','approve','group',true,null,now()-interval '1 hour',null);
GRANT USAGE ON SCHEMA public,auth,core,ops,accounting,system TO service_role,authenticated;
