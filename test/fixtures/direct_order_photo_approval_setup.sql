-- Only the unrelated catalogue/Auth setup is reduced. The runner loads the
-- real payment function, direct tables, actor checks and approval migrations.
CREATE TABLE auth.users(id uuid PRIMARY KEY, email text,raw_app_meta_data jsonb DEFAULT '{}');
INSERT INTO auth.users(id,email) VALUES(auth.uid(),'bt_pos1@globos.world'),('00000000-0000-4000-8000-000000000002','photo_kitchen@globos.world');
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$
 SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.sub',true), '')::uuid,
 '00000000-0000-4000-8000-000000000001'::uuid)
$$;
ALTER TABLE public.users ADD COLUMN restaurant_id uuid;
CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql AS $$
 SELECT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND role='super_admin' AND is_active)
$$;
CREATE OR REPLACE FUNCTION public.user_accessible_stores(uuid)
RETURNS TABLE(store_id uuid) LANGUAGE sql AS $$
 SELECT restaurant_id FROM public.users WHERE auth_id=$1 AND is_active
$$;
ALTER TABLE public.orders ADD COLUMN sales_channel text,
 ADD COLUMN guest_count integer, ADD COLUMN created_by uuid,
 ADD COLUMN notes text, ADD COLUMN order_source text,
 ADD COLUMN fulfillment_mode_snapshot text;
ALTER TABLE public.order_items ADD COLUMN notes text,
 ADD COLUMN fulfillment_mode_snapshot text;
ALTER TABLE public.menu_items ADD COLUMN restaurant_id uuid,
 ADD COLUMN name text, ADD COLUMN name_ko text, ADD COLUMN name_vi text,
 ADD COLUMN name_en text, ADD COLUMN price numeric,
 ADD COLUMN is_available boolean DEFAULT true,
 ADD COLUMN is_visible_public boolean DEFAULT true;
CREATE TABLE public.restaurant_settings(restaurant_id uuid,fulfillment_mode text);
CREATE TABLE public.emergency_fulfillment_sessions(restaurant_id uuid,status text);
CREATE TABLE public.store_promotions(restaurant_id uuid,is_active boolean,starts_at timestamptz,ends_at timestamptz);
-- The real receipt trigger is loaded by the runner. Its external print enqueue
-- dependency can fail without turning an accepted payment into a failed order.
CREATE FUNCTION public.enqueue_receipt_print_job(uuid,boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('photo_test.receipt_failure',true)='on' THEN
 RAISE EXCEPTION 'PHOTO_TEST_RECEIPT_QUEUE_FAILED'; END IF;
 RETURN jsonb_build_object('status','pending');
END $$;
