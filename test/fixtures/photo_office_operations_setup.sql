-- Disposable local extension of pos_payroll_inputs_setup.sql.
create extension if not exists pg_stat_statements;
create table public.restaurants(id uuid primary key,name text,brand_id uuid,is_active boolean default true);
insert into public.restaurants values
('20000000-0000-0000-0000-000000000001','Photo fixture A','77000000-0000-0000-0000-000000000001',true),
('20000000-0000-0000-0000-000000000002','Photo fixture B','77000000-0000-0000-0000-000000000001',true),
('20000000-0000-0000-0000-000000000003','Other brand','99900000-0000-0000-0000-000000000001',true);
alter table public.store_employees add column employment_start_date date;
alter table public.employee_hourly_pay_rules add column updated_at timestamptz default now();
create table public.inventory_items(id uuid primary key,restaurant_id uuid references public.restaurants(id),name text,unit text,quantity numeric default 0,current_stock numeric,reorder_point numeric,is_active boolean default true,updated_at timestamptz default now());
create table public.inventory_physical_counts(id uuid primary key default gen_random_uuid(),restaurant_id uuid,ingredient_id uuid,count_date date,actual_quantity_g numeric,theoretical_quantity_g numeric,variance_g numeric,counted_by uuid,note text,updated_at timestamptz,unique(ingredient_id,count_date));
create table public.inventory_transactions(id uuid primary key default gen_random_uuid(),restaurant_id uuid,ingredient_id uuid,transaction_type text,quantity_g numeric,reference_type text,reference_id uuid,note text,stock_before numeric,stock_after numeric,effective_date date);
insert into public.inventory_items(id,restaurant_id,name,unit,current_stock) values
('50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Tissue','pack',0.5),
('50000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','Pen','ea',8),
('50000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','Film','box',1.9);
-- Preserve the exact staff-query seam modified by the forward migration.
create function public.get_financial_input_page() returns text language plpgsql security definer as $$
declare v_query text;begin v_query:='SELECT id, store_id, employee_number, full_name, employment_role
 FROM public.store_employees WHERE store_id = ANY($1)';return v_query;end $$;
create function public.get_employee_financial_input_page() returns text language plpgsql security definer as $$
declare v_query text;begin v_query:='SELECT id, store_id, employee_number, full_name, employment_role
 FROM public.store_employees WHERE store_id = ANY($1) AND id = $9';return v_query;end $$;
-- Existing single-employee contract is replaced by the forward migration.
create function public.office_photo_payroll_inputs(uuid,uuid,date,date) returns jsonb language sql stable security definer as $$select '{}'::jsonb$$;

-- Existing Photo read models are installed before the new forward migration.
alter table public.store_employees add column phone text, add column bank_name text,
 add column bank_account_number text, add column probation_start_date date,
 add column updated_at timestamptz;
create table public.photo_objet_sales(store_id uuid,sale_date date,gross_sales numeric,transaction_count integer,pulled_at timestamptz);
create table public.daily_closings(restaurant_id uuid,closing_date date,payments_cash numeric,payments_bank_transfer numeric,created_at timestamptz);
create table public.orders(restaurant_id uuid,status text,created_at timestamptz);
create table public.payment_adjustments(restaurant_id uuid,adjustment_type text,amount numeric,created_at timestamptz);
create table public.payroll_records(restaurant_id uuid,total_amount numeric,period_start date,period_end date,status text,updated_at timestamptz);
