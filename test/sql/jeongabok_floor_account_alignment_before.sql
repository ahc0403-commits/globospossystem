ALTER TABLE public.users ADD COLUMN fixed_account_code text;
ALTER TABLE public.emergency_station_assignments ADD COLUMN user_id uuid,
 ADD COLUMN floor_label text,ADD COLUMN updated_at timestamptz DEFAULT now();
ALTER TABLE public.emergency_station_assignments ADD UNIQUE(restaurant_id,user_id);
CREATE TABLE public.restaurant_settings(restaurant_id uuid PRIMARY KEY,
 floor_direct_beverages_enabled boolean NOT NULL DEFAULT false,updated_at timestamptz DEFAULT now());
INSERT INTO public.restaurant_settings(restaurant_id) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849'),('90000000-0000-4000-8000-000000000001');
INSERT INTO public.users(id,restaurant_id,is_active,fixed_account_code) VALUES
 ('80000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849',true,'jgbt_floor_1f'),
 ('80000000-0000-4000-8000-000000000002','273b057e-3b69-46e3-93c1-6194c2802849',true,'jgbt_floor_2f'),
 ('80000000-0000-4000-8000-000000000003','90000000-0000-4000-8000-000000000001',true,'other_floor_1f');
INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,floor_label,is_active)
SELECT restaurant_id,id,'floor',CASE WHEN fixed_account_code LIKE '%2f' THEN '2F' ELSE '1F' END,true
FROM public.users WHERE id::text LIKE '80000000%';
