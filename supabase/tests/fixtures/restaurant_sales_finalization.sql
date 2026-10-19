create table public.restaurants(id uuid primary key,name text,brand_id uuid,store_type text,is_active boolean default true);
create table public.orders(id uuid primary key,status text,sales_channel text);
create table public.payments(id uuid primary key,order_id uuid,restaurant_id uuid,amount numeric,amount_portion numeric,is_revenue boolean,created_at timestamptz);
create table public.external_sales(id uuid primary key,restaurant_id uuid,gross_amount numeric,is_revenue boolean,order_status text,sales_channel text,completed_at timestamptz,created_at timestamptz);
create table public.restaurant_daily_sales_finalizations(id uuid primary key default gen_random_uuid(),business_date date unique,status text,store_count integer,receipt_count integer,gross_sales numeric,post_cutoff_receipt_count integer,offending_stores jsonb,observed_at timestamptz,finalized_at timestamptz,created_at timestamptz default now());
create function public.enforce_restaurant_finalization_immutable() returns trigger language plpgsql as $$begin raise exception 'RESTAURANT_FINALIZATION_IMMUTABLE';end$$;
create trigger trg_restaurant_finalization_immutable before update or delete on public.restaurant_daily_sales_finalizations for each row execute function public.enforce_restaurant_finalization_immutable();
insert into public.restaurants values
 ('10000000-0000-0000-0000-000000000001','Restaurant','20000000-0000-0000-0000-000000000001','direct',true),
 ('10000000-0000-0000-0000-000000000002','Photo','77000000-0000-0000-0000-000000000001','direct',true),
 ('10000000-0000-0000-0000-000000000003','External sample','20000000-0000-0000-0000-000000000001','external',true);
insert into public.orders values('40000000-0000-0000-0000-000000000001','completed','dine_in');
insert into public.payments values
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',1000,600,true,'2026-10-05 20:00+07'),
 ('50000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',1000,400,true,'2026-10-05 20:00+07'),
 ('50000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',99000,null,true,'2026-10-05 20:00+07'),
 ('50000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003',88000,null,true,'2026-10-05 20:00+07'),
 ('50000000-0000-0000-0000-000000000005','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',7000,null,false,'2026-10-05 20:00+07'),
 ('50000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',100,null,true,'2026-10-06 21:45+07');
insert into public.restaurant_daily_sales_finalizations(business_date,status,store_count,receipt_count,gross_sales,post_cutoff_receipt_count,offending_stores,observed_at,finalized_at)
select d::date,'finalized',0,0,0,0,'[]'::jsonb,d+time '22:20',d+time '22:20' from generate_series(timestamp '2026-10-05',timestamp '2026-10-06',interval '1 day') d;
