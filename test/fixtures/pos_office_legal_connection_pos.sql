CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT current_setting('request.jwt.claim.role',true) $$;
CREATE TABLE public.users(auth_id uuid REFERENCES auth.users,role text,is_active boolean);
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND role='super_admin' AND is_active) $$;
CREATE TABLE public.tax_entity(id uuid PRIMARY KEY,name text,tax_code text,owner_type text);
CREATE TABLE public.restaurants(id uuid PRIMARY KEY,tax_entity_id uuid REFERENCES public.tax_entity);
INSERT INTO auth.users VALUES
 ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002'),('10000000-0000-4000-8000-000000000003');
INSERT INTO public.users VALUES
 ('10000000-0000-4000-8000-000000000001','super_admin',true),
 ('10000000-0000-4000-8000-000000000002','cashier',true),
 ('10000000-0000-4000-8000-000000000003','super_admin',true);
INSERT INTO public.tax_entity VALUES
 ('30000000-0000-4000-8000-000000000001','Fixture legal A','TAX-A','internal'),
 ('30000000-0000-4000-8000-000000000002','Fixture legal B','TAX-B','internal'),
 ('30000000-0000-4000-8000-000000000003','Fixture external','TAX-EXT','external');
GRANT USAGE ON SCHEMA public,auth TO authenticated,service_role;
GRANT SELECT ON public.users TO authenticated;
