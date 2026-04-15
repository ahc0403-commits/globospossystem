create table if not exists accounting.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  store_id uuid not null references ops.stores(id),
  brand_id uuid not null references ops.brands(id),
  amount numeric(15,2) not null,
  requested_date date not null,
  status accounting.request_status not null,
  created_at timestamptz not null default now()
);
create table if not exists accounting.expenses (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  submitted_by text not null,
  store_id uuid not null references ops.stores(id),
  amount numeric(15,2) not null,
  expense_date date not null,
  status accounting.expense_status not null,
  return_note text null,
  created_at timestamptz not null default now()
);
create table if not exists accounting.payables (
  id uuid primary key default gen_random_uuid(),
  vendor text not null,
  description text not null,
  amount numeric(15,2) not null,
  due_date date not null,
  status accounting.payable_status not null,
  store_id uuid references ops.stores(id),
  brand_id uuid references ops.brands(id),
  created_at timestamptz not null default now()
);
create table if not exists accounting.accounting_entries (
  id uuid primary key default gen_random_uuid(),
  entry text not null,
  account text not null,
  debit numeric(15,2),
  credit numeric(15,2),
  period text not null,
  created_at timestamptz not null default now()
);
