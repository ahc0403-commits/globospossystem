CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE TABLE public.orders(id uuid PRIMARY KEY,restaurant_id uuid,table_id uuid,status text,created_at timestamptz,updated_at timestamptz);
CREATE TABLE public.table_qr_tokens(token text PRIMARY KEY,restaurant_id uuid,table_id uuid,is_active boolean);
CREATE TABLE public.order_items(id uuid PRIMARY KEY,order_id uuid,restaurant_id uuid,status text,item_type text,is_service_item boolean,created_at timestamptz,name text,quantity integer);
CREATE TABLE public.qr_order_display_states(order_id uuid PRIMARY KEY,visible_from timestamptz,display_version bigint,reset_applied_at timestamptz,reset_due_at timestamptz);
CREATE FUNCTION public.kds_is_direct_floor_store(p_store_id uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT p_store_id='273b057e-3b69-46e3-93c1-6194c2802849'::uuid;
$$;
-- Preserve the predecessor's token and active-order boundary. Only display
-- state application is stubbed: the fixture starts after a due reset.
CREATE FUNCTION public.qr_get_active_order_pre_display_reset(p_token text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE q record; o record;
BEGIN
 SELECT * INTO q FROM public.table_qr_tokens WHERE token=p_token AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;
 SELECT * INTO o FROM public.orders WHERE restaurant_id=q.restaurant_id AND table_id=q.table_id
  AND status IN ('pending','confirmed','serving') ORDER BY created_at DESC LIMIT 1;
 IF NOT FOUND THEN RETURN '{"active":false,"items":[]}'::jsonb; END IF;
 RETURN jsonb_build_object('active',true,'order_id',o.id,'items',(
  SELECT coalesce(jsonb_agg(jsonb_build_object('name',name,'quantity',quantity) ORDER BY created_at,id),'[]'::jsonb)
  FROM public.order_items WHERE order_id=o.id AND restaurant_id=q.restaurant_id
   AND status<>'cancelled' AND item_type='menu_item' AND NOT coalesce(is_service_item,false)));
END $$;
CREATE FUNCTION public.qr_apply_due_order_display_reset(p_order_id uuid)
RETURNS public.qr_order_display_states LANGUAGE sql AS $$
 SELECT * FROM public.qr_order_display_states WHERE order_id=p_order_id;
$$;
