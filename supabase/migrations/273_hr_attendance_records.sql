-- 273: HR Attendance Records — canonical office-owned attendance table
-- Bundle B-1: foundation table + RLS + indexes (no Flutter pages yet)

-- Enum for attendance status
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'attendance_status'
  ) then
    create type hr.attendance_status as enum ('present', 'absent', 'late', 'half_day', 'holiday', 'leave');
  end if;
end $$;
-- Enum for attendance source
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'attendance_source'
  ) then
    create type hr.attendance_source as enum ('manual', 'pos_bridge', 'system');
  end if;
end $$;
-- Table
create table if not exists hr.attendance_records (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references hr.employees(id),
  store_id      uuid not null references ops.stores(id),
  brand_id      uuid not null references ops.brands(id),
  attendance_date date not null,
  check_in_at   timestamptz,
  check_out_at  timestamptz,
  worked_minutes int,
  status        hr.attendance_status not null default 'present',
  source        hr.attendance_source not null default 'manual',
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- One record per employee per day
  constraint uq_attendance_employee_date unique (employee_id, attendance_date)
);
-- Indexes
create index if not exists idx_attendance_store_date
  on hr.attendance_records (store_id, attendance_date);
create index if not exists idx_attendance_brand_date
  on hr.attendance_records (brand_id, attendance_date);
create index if not exists idx_attendance_employee
  on hr.attendance_records (employee_id);
-- RLS
alter table hr.attendance_records enable row level security;
-- Select: superAdmin sees all, brandManager sees own brand, storeManager sees own store, staff sees own records
drop policy if exists attendance_select_scoped on hr.attendance_records;
create policy attendance_select_scoped on hr.attendance_records
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
-- Insert: superAdmin, brandManager, storeManager can create records within their scope
drop policy if exists attendance_insert_scoped on hr.attendance_records;
create policy attendance_insert_scoped on hr.attendance_records
  for insert
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- Update: superAdmin, brandManager, storeManager can update records within their scope
drop policy if exists attendance_update_scoped on hr.attendance_records;
create policy attendance_update_scoped on hr.attendance_records
  for update
  using (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  )
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- updated_at trigger
create or replace function hr.set_attendance_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
drop trigger if exists trg_attendance_updated_at on hr.attendance_records;
create trigger trg_attendance_updated_at
  before update on hr.attendance_records
  for each row execute function hr.set_attendance_updated_at();
