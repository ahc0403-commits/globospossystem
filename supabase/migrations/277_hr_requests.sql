-- 277: HR Requests — canonical office-owned operational request table
-- Bundle E-1: foundation table + RLS + indexes
-- Note: Self-submit from My Requests remains blocked by DEC-010. This is admin/read foundation only.

-- Enum for request type
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'request_type'
  ) then
    create type hr.request_type as enum ('schedule_change', 'equipment', 'training', 'other');
  end if;
end $$;
-- Enum for request status
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'request_status'
  ) then
    create type hr.request_status as enum ('pending', 'approved', 'rejected', 'completed');
  end if;
end $$;
-- Table
create table if not exists hr.requests (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references hr.employees(id),
  store_id      uuid not null references ops.stores(id),
  brand_id      uuid not null references ops.brands(id),
  request_type  hr.request_type not null,
  subject       text not null,
  details       text,
  status        hr.request_status not null default 'pending',
  submitted_by  uuid references core.accounts(id),
  reviewed_by   uuid references core.accounts(id),
  reviewed_at   timestamptz,
  review_note   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
-- Indexes
create index if not exists idx_requests_store
  on hr.requests (store_id);
create index if not exists idx_requests_brand
  on hr.requests (brand_id);
create index if not exists idx_requests_employee
  on hr.requests (employee_id);
create index if not exists idx_requests_status
  on hr.requests (status);
-- RLS
alter table hr.requests enable row level security;
-- Select: superAdmin sees all, brandManager sees own brand, storeManager sees own store
drop policy if exists requests_select_scoped on hr.requests;
create policy requests_select_scoped on hr.requests
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
-- Insert: superAdmin and brandManager/storeManager within their scope
-- (foundation-only: admin can seed records; DEC-010 self-submit is NOT implemented here)
drop policy if exists requests_insert_scoped on hr.requests;
create policy requests_insert_scoped on hr.requests
  for insert
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- Update: superAdmin and brandManager/storeManager within their scope
drop policy if exists requests_update_scoped on hr.requests;
create policy requests_update_scoped on hr.requests
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
create or replace function hr.set_requests_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
drop trigger if exists trg_requests_updated_at on hr.requests;
create trigger trg_requests_updated_at
  before update on hr.requests
  for each row execute function hr.set_requests_updated_at();
