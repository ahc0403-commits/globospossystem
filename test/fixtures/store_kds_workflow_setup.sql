CREATE TABLE public.orders(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,status text);
ALTER TABLE public.emergency_fulfillment_items ADD COLUMN restaurant_id uuid, ADD COLUMN excused_quantity int NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_floor_direct_items ADD COLUMN restaurant_id uuid, ADD COLUMN excused_quantity int NOT NULL DEFAULT 0;
CREATE TABLE public.leftover_packaging_requests(restaurant_id uuid,status text);
CREATE FUNCTION public.kds_is_direct_floor_store(uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT coalesce($1='273b057e-3b69-46e3-93c1-6194c2802849'::uuid,false); $$;
CREATE TABLE public.emergency_order_queue(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,kitchen_direct_to_floor boolean DEFAULT false,
 CONSTRAINT kds_direct_floor_store_scope CHECK(NOT kitchen_direct_to_floor OR public.kds_is_direct_floor_store(restaurant_id)));
CREATE FUNCTION public.kds_assign_direct_floor_workflow() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN NEW.kitchen_direct_to_floor:=public.kds_is_direct_floor_store(NEW.restaurant_id); RETURN NEW; END; $$;
CREATE TRIGGER kds_assign_direct_floor_workflow BEFORE INSERT ON public.emergency_order_queue
 FOR EACH ROW EXECUTE FUNCTION public.kds_assign_direct_floor_workflow();
INSERT INTO public.restaurants(id,name) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849','JeonGabok'),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','BunsikClub'),
 ('20000000-0000-4000-8000-000000000004','New store');
INSERT INTO public.restaurant_settings(restaurant_id) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849'),('8bc9eef5-dcd5-46b1-b931-23f77132322c');

CREATE FUNCTION public.emergency_add_order_batch_timings(p_orders jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_agg(public.kds_is_direct_floor_store(q.restaurant_id)) FROM public.emergency_order_queue q;
$$;
