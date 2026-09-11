CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA auth;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA storage;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.role',true),''),'authenticated') $$;
GRANT USAGE ON SCHEMA auth, public, extensions TO authenticated,anon,service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO authenticated,anon,service_role;
CREATE TABLE public.brands(id uuid PRIMARY KEY);
CREATE TABLE public.restaurants(id uuid PRIMARY KEY,brand_id uuid REFERENCES public.brands(id),tax_entity_id uuid,name text,is_active boolean DEFAULT true);
CREATE TABLE public.users(id uuid PRIMARY KEY,auth_id uuid,role text,restaurant_id uuid,primary_store_id uuid,is_active boolean DEFAULT true,full_name text,extra_permissions text[] DEFAULT '{}');
CREATE TABLE public.user_store_access(user_id uuid,store_id uuid,is_active boolean DEFAULT true);
CREATE TABLE public.user_tax_entity_access(user_id uuid,tax_entity_id uuid,is_active boolean DEFAULT true);
CREATE FUNCTION public.has_any_role(roles text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
 SELECT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active AND role=ANY(roles)) $$;
CREATE TABLE public.inventory_items(id uuid PRIMARY KEY,restaurant_id uuid,current_stock numeric DEFAULT 0,quantity numeric DEFAULT 0,updated_at timestamptz);
CREATE TABLE public.inventory_transactions(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,ingredient_id uuid,transaction_type text,quantity_g numeric,reference_type text,reference_id uuid,note text,created_by uuid);
CREATE TABLE public.audit_logs(id uuid DEFAULT gen_random_uuid(),actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text,metadata jsonb,owner_id text);
CREATE FUNCTION public.test_uuid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;

CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1]
$$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT SELECT,INSERT ON storage.objects TO authenticated;
