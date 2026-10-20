\set ON_ERROR_STOP on
BEGIN;
INSERT INTO public.orders(id,restaurant_id,status)
VALUES('96000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849','pending');
INSERT INTO public.menu_items(id,restaurant_id,name,price)
VALUES('96000000-0000-4000-8000-000000000002','273b057e-3b69-46e3-93c1-6194c2802849','RLS laboratory',10000);
INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,unit_price,quantity)
VALUES('273b057e-3b69-46e3-93c1-6194c2802849','96000000-0000-4000-8000-000000000001','96000000-0000-4000-8000-000000000002','RLS laboratory',10000,1);
-- The no-privileges schema clone needs fixture-only table grants to exercise
-- the actual production policies as an authenticated, already-issued JWT.
GRANT USAGE ON SCHEMA public,auth TO authenticated;
GRANT SELECT ON public.users,public.orders,public.order_items,public.kds_change_log,public.emergency_order_queue,public.emergency_fulfillment_items TO authenticated;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims='{"sub":"92000000-0000-4000-8000-000000000002","role":"authenticated"}';
DO $$ BEGIN
 ASSERT NOT EXISTS(SELECT 1 FROM public.orders WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
 ASSERT NOT EXISTS(SELECT 1 FROM public.order_items WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
 ASSERT NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_order_queue WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'JEONGABOK_RETIRED_CHECKER_JWT_RLS=PASS';
