create table if not exists core.accounts (
  id uuid primary key,
  name text not null,
  email text not null unique,
  role text not null check (role in ('superAdmin', 'brandManager', 'storeManager', 'staff')),
  scope_brand_id uuid null,
  scope_store_id uuid null,
  status core.account_status not null,
  created_at timestamptz not null default now(),
  last_login_at timestamptz null
);
create table if not exists core.account_permissions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references core.accounts(id) on delete cascade,
  domain core.permission_domain not null,
  action core.permission_action not null,
  scope core.scope_level not null default 'self',
  scope_brand_id uuid,
  scope_store_id uuid,
  granted_at timestamptz not null default now(),
  granted_by uuid references core.accounts(id),
  unique(account_id, domain, action, scope_brand_id, scope_store_id)
);
