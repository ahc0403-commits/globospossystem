-- Disposable local fixture only; contains no production data.
create role anon;
create role authenticated;
create role service_role;
create table public.store_employees (
  id uuid primary key,store_id uuid,employee_number text,full_name text,
  employment_role text,is_active boolean
);
create table public.attendance_logs (
  id uuid primary key,restaurant_id uuid,employee_id uuid,user_id uuid,type text,logged_at timestamptz
);
create index attendance_logs_employee_time_idx on public.attendance_logs(employee_id,logged_at desc) where employee_id is not null;
create index attendance_logs_store_logged_at_idx on public.attendance_logs(restaurant_id,logged_at desc);
create table public.employee_daily_allowances (
  id uuid primary key,store_id uuid,employee_id uuid,work_date date,is_split_shift boolean,
  meal_allowance_amount numeric,parking_allowance_amount numeric,
  updated_at timestamptz default now(),
  unique(store_id,employee_id,work_date)
);
create table public.employee_hourly_pay_rules (
  employee_id uuid primary key,store_id uuid,hourly_rate numeric,scheduled_start text,
  night_start text,night_multiplier numeric,holiday_multiplier numeric,exclude_sunday boolean,
  late_threshold_minutes int,late_review_hourly_multiplier numeric
);
create table public.vietnam_public_holidays(holiday_date date primary key,is_active boolean);
grant usage on schema public to anon,authenticated,service_role;
-- Match production: service_role cannot read the workforce/allowance bases.
grant select on public.attendance_logs,public.employee_hourly_pay_rules,
  public.vietnam_public_holidays to service_role;
insert into public.store_employees values
('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','PT1','Fixture A','part_timer',true),
('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','PT2','Fixture B','part_timer',true);
insert into public.attendance_logs values
('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',null,'clock_in','2026-09-30T17:00:00Z'),
('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',null,'clock_out','2026-10-15T16:59:59Z'),
('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',null,'clock_out','2026-10-15T17:00:00Z'),
-- A POS login UUID matching the workforce UUID must not import a login event.
('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001',null,'10000000-0000-0000-0000-000000000001','clock_in','2026-10-02T02:00:00Z');
insert into public.employee_daily_allowances
 (id,store_id,employee_id,work_date,is_split_shift,meal_allowance_amount,parking_allowance_amount) values
('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','2026-10-01',true,25000,5000);
insert into public.employee_hourly_pay_rules values
('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',30000,'09:00','22:00',1.3,3,true,60,2);
insert into public.vietnam_public_holidays values ('2026-10-02',true),('2026-10-03',false),('2026-09-02',true);
