CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.users(id uuid PRIMARY KEY,auth_id uuid UNIQUE,is_active boolean,role text);
CREATE TABLE public.fixture_store_access(auth_id uuid,store_id uuid);
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active AND role='super_admin') $$;
CREATE FUNCTION public.user_accessible_stores(uuid) RETURNS TABLE(store_id uuid)
 LANGUAGE sql STABLE AS $$ SELECT store_id FROM public.fixture_store_access WHERE auth_id=$1 $$;
CREATE TABLE public.emergency_fulfillment_events(event_id uuid PRIMARY KEY,session_id uuid,
 restaurant_id uuid,actor_user_id uuid,order_item_id uuid,floor_direct_item_id uuid,
 combo_component_item_id uuid,stage text,delta integer,details jsonb DEFAULT '{}');
CREATE TABLE public.emergency_kitchen_batch_actions(request_id uuid PRIMARY KEY,restaurant_id uuid,
 allocation_hash text NOT NULL,response jsonb NOT NULL,created_by uuid,created_at timestamptz DEFAULT now());
ALTER TABLE public.emergency_kitchen_batch_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.emergency_kitchen_batch_actions FROM PUBLIC,anon,authenticated;
INSERT INTO public.users VALUES
 ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',true,'kitchen'),
 ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002',true,'kitchen'),
 ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003',false,'kitchen');
INSERT INTO public.fixture_store_access VALUES
 ('10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001');
INSERT INTO public.emergency_fulfillment_events VALUES
 ('50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
 '30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000001',NULL,NULL,'kitchen_done',1,
 '{"workflow_action":"kitchen_done","source_kind":"base","source_id":"90000000-0000-4000-8000-000000000001","response":{"not_exposed":true}}');
INSERT INTO public.emergency_kitchen_batch_actions VALUES
 ('60000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','synthetic-hash',
 '{"event_ids":["50000000-0000-4000-8000-000000000001"]}',
 '20000000-0000-4000-8000-000000000001',now());
