create table if not exists ops.brands (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status core.account_status not null,
  region text default '',
  currency text default '',
  tax_scheme text default '',
  created_at timestamptz not null default now()
);
create table if not exists ops.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand_id uuid not null references ops.brands(id),
  status core.account_status not null,
  created_at timestamptz not null default now(),
  address text default '',
  zone text default '',
  manager_name text default '',
  operating_hours text default ''
);
do $$
begin
  if not exists (
    select 1
    from information_schema.table_constraints
    where constraint_name = 'accounts_scope_brand_fk'
      and table_schema = 'core'
      and table_name = 'accounts'
  ) then
    alter table core.accounts
      add constraint accounts_scope_brand_fk
      foreign key (scope_brand_id) references ops.brands(id);
  end if;

  if not exists (
    select 1
    from information_schema.table_constraints
    where constraint_name = 'accounts_scope_store_fk'
      and table_schema = 'core'
      and table_name = 'accounts'
  ) then
    alter table core.accounts
      add constraint accounts_scope_store_fk
      foreign key (scope_store_id) references ops.stores(id);
  end if;

  if not exists (
    select 1
    from information_schema.table_constraints
    where constraint_name = 'account_permissions_brand_fk'
      and table_schema = 'core'
      and table_name = 'account_permissions'
  ) then
    alter table core.account_permissions
      add constraint account_permissions_brand_fk
      foreign key (scope_brand_id) references ops.brands(id);
  end if;

  if not exists (
    select 1
    from information_schema.table_constraints
    where constraint_name = 'account_permissions_store_fk'
      and table_schema = 'core'
      and table_name = 'account_permissions'
  ) then
    alter table core.account_permissions
      add constraint account_permissions_store_fk
      foreign key (scope_store_id) references ops.stores(id);
  end if;
end $$;
