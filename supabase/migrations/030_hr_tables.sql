create table if not exists hr.employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text not null,
  store_id uuid not null references ops.stores(id),
  brand_id uuid not null references ops.brands(id),
  status core.account_status not null,
  email text default '',
  phone text default '',
  start_date date,
  employment_type text default ''
);
create table if not exists hr.payroll_records (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references hr.employees(id),
  employee_name text not null,
  role text not null,
  store_id uuid not null references ops.stores(id),
  brand_id uuid not null references ops.brands(id),
  period_date date not null,
  status hr.payroll_status not null,
  hours_worked numeric(7,2),
  regular_pay numeric(15,2),
  overtime_pay numeric(15,2),
  deductions numeric(15,2),
  net_pay numeric(15,2),
  days_present int default 0,
  days_absent int default 0,
  has_exception boolean default false,
  exception_note text null
);
