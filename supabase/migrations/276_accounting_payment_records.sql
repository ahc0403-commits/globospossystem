-- Bundle D-2: Accounting Payment Status
-- Smallest correct foundation for payment execution visibility.
-- Links to accounting.payables for payable-cycle grounding.

-- Enum for payment record status
do $$ begin
  create type accounting.payment_record_status as enum (
    'scheduled',
    'processing',
    'completed',
    'failed',
    'cancelled'
  );
exception when duplicate_object then null;
end $$;
-- Enum for payment method
do $$ begin
  create type accounting.payment_method as enum (
    'bank_transfer',
    'cash',
    'card',
    'other'
  );
exception when duplicate_object then null;
end $$;
create table if not exists accounting.payment_records (
  id uuid primary key default gen_random_uuid(),
  payable_id uuid references accounting.payables(id),
  store_id uuid references ops.stores(id),
  brand_id uuid references ops.brands(id),
  payment_reference text,
  payment_method accounting.payment_method not null default 'bank_transfer',
  amount numeric(15,2) not null,
  status accounting.payment_record_status not null default 'scheduled',
  scheduled_at date,
  paid_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Index for common queries
create index if not exists idx_payment_records_status
  on accounting.payment_records(status);
create index if not exists idx_payment_records_payable
  on accounting.payment_records(payable_id);
create index if not exists idx_payment_records_brand
  on accounting.payment_records(brand_id);
-- RLS: consistent with existing accounting patterns
alter table accounting.payment_records enable row level security;
drop policy if exists payment_records_select_scoped on accounting.payment_records;
create policy payment_records_select_scoped on accounting.payment_records
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
-- updated_at auto-touch trigger
create or replace function accounting.touch_payment_records_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_payment_records_updated_at on accounting.payment_records;
create trigger trg_payment_records_updated_at
before update on accounting.payment_records
for each row
execute function accounting.touch_payment_records_updated_at();
