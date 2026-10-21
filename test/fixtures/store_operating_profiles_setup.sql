CREATE TABLE public.brands(id uuid PRIMARY KEY,management_model text);
CREATE TABLE public.restaurants(id uuid PRIMARY KEY,name text NOT NULL,is_active boolean DEFAULT true,brand_id uuid REFERENCES brands(id));
CREATE TABLE public.users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),auth_id uuid,role text,is_active boolean DEFAULT true,restaurant_id uuid REFERENCES restaurants(id));
CREATE TABLE public.fixture_store_access(auth_id uuid,store_id uuid);
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND role='super_admin' AND is_active) $$;
CREATE FUNCTION public.user_accessible_stores(uuid) RETURNS SETOF uuid LANGUAGE sql STABLE AS $$
 SELECT store_id FROM public.fixture_store_access WHERE auth_id=$1 $$;
CREATE TABLE public.restaurant_settings(restaurant_id uuid PRIMARY KEY REFERENCES restaurants(id),fulfillment_mode text,kds_workflow text);
CREATE TABLE public.tables(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid REFERENCES restaurants(id),table_number text,floor_label text);
CREATE TABLE public.emergency_station_assignments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid REFERENCES restaurants(id),user_id uuid REFERENCES users(id),station_type text,floor_label text,is_active boolean DEFAULT true,UNIQUE(restaurant_id,user_id));
CREATE TABLE public.audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
GRANT USAGE ON SCHEMA public TO authenticated;
