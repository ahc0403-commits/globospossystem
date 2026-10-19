CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT 'a1000000-0000-4000-8000-000000000001'::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT current_user::text $$;
CREATE TABLE public.users(id uuid PRIMARY KEY, auth_id uuid, role text, is_active boolean);
INSERT INTO public.users VALUES(auth.uid(), auth.uid(), 'admin', true);
CREATE TABLE public.restaurants(id uuid PRIMARY KEY);
INSERT INTO public.restaurants VALUES('a2000000-0000-4000-8000-000000000001');
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE FUNCTION public.get_user_restaurant_id() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT id FROM public.restaurants LIMIT 1 $$;
CREATE FUNCTION public.get_user_store_id() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT public.get_user_restaurant_id() $$;
CREATE FUNCTION public.has_any_role(text[]) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE FUNCTION public.user_accessible_stores(uuid) RETURNS TABLE(store_id uuid)
LANGUAGE sql STABLE AS $$ SELECT id FROM public.restaurants $$;
CREATE TABLE public.orders(id uuid PRIMARY KEY, restaurant_id uuid, sales_channel text, status text);
CREATE TABLE public.payments(order_id uuid, amount numeric, created_at timestamptz, is_revenue boolean);
CREATE TABLE public.audit_logs(actor_id uuid, action text, entity_type text, entity_id uuid, details jsonb);

-- pg_cron catalogue/unschedule stand-in; actual migration code is exercised.
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobid bigint PRIMARY KEY, jobname text, command text);
INSERT INTO cron.job VALUES
  (1,'deliberry-dispatcher','SELECT 1'),
  (2,'biweekly-close','POST /functions/v1/generate-settlement'),
  (3,NULL,'POST /functions/v1/generate_delivery_settlement'),
  (4,'meinvoice-dispatcher','SELECT 2'),
  (5,'scheduled-cash-close','SELECT 3');
CREATE FUNCTION cron.unschedule(bigint) RETURNS boolean LANGUAGE sql AS
$$ DELETE FROM cron.job WHERE jobid=$1 RETURNING true $$;
