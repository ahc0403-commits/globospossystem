-- 274: HR Leave Requests — canonical office-owned leave table
-- Bundle B-2: foundation table + RLS + indexes (no Flutter pages yet)
-- Note: My Leave submit flow remains blocked by DEC-010. This is admin/read foundation only.

-- Enum for leave type
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'leave_type'
  ) then
    create type hr.leave_type as enum ('annual', 'sick', 'personal', 'unpaid');
  end if;
end $$;
-- Enum for leave request status
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'leave_status'
  ) then
    create type hr.leave_status as enum ('pending', 'approved', 'rejected');
  end if;
end $$;
-- Table
create table if not exists hr.leave_requests (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references hr.employees(id),
  store_id      uuid not null references ops.stores(id),
  brand_id      uuid not null references ops.brands(id),
  leave_type    hr.leave_type not null,
  start_date    date not null,
  end_date      date not null,
  day_count     int not null,
  status        hr.leave_status not null default 'pending',
  requested_by  uuid references core.accounts(id),
  reviewed_by   uuid references core.accounts(id),
  reviewed_at   timestamptz,
  reason        text,
  review_note   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint chk_leave_dates check (end_date >= start_date),
  constraint chk_leave_day_count check (day_count > 0)
);
-- Indexes
create index if not exists idx_leave_store_date
  on hr.leave_requests (store_id, start_date);
create index if not exists idx_leave_brand_date
  on hr.leave_requests (brand_id, start_date);
create index if not exists idx_leave_employee
  on hr.leave_requests (employee_id);
create index if not exists idx_leave_status
  on hr.leave_requests (status);
-- RLS
alter table hr.leave_requests enable row level security;
-- Select: superAdmin sees all, brandManager sees own brand, storeManager sees own store
drop policy if exists leave_select_scoped on hr.leave_requests;
create policy leave_select_scoped on hr.leave_requests
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
-- Insert: superAdmin and brandManager/storeManager within their scope
-- (foundation-only: admin can seed records; DEC-010 self-submit is NOT implemented here)
drop policy if exists leave_insert_scoped on hr.leave_requests;
create policy leave_insert_scoped on hr.leave_requests
  for insert
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- Update: superAdmin and brandManager/storeManager within their scope
drop policy if exists leave_update_scoped on hr.leave_requests;
create policy leave_update_scoped on hr.leave_requests
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
create or replace function hr.set_leave_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
drop trigger if exists trg_leave_updated_at on hr.leave_requests;
create trigger trg_leave_updated_at
  before update on hr.leave_requests
  for each row execute function hr.set_leave_updated_at();
