-- Office integration Phase 1: Office user profiles with multi-dimensional permissions

create table if not exists public.office_user_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid not null references auth.users(id) unique,
  company_id uuid references companies(id),
  account_level text not null check (account_level in (
    'super_admin',
    'platform_admin',
    'office_admin',
    'brand_admin',
    'store_admin',
    'staff'
  )),
  domain_authorities jsonb default '[]',
  scope_type text not null default 'global' check (scope_type in ('global', 'brand', 'store')),
  scope_ids uuid[] default '{}',
  display_name text not null,
  email text,
  is_active boolean default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_office_users_auth_id on public.office_user_profiles(auth_id);
create index if not exists idx_office_users_company on public.office_user_profiles(company_id);
create index if not exists idx_office_users_scope on public.office_user_profiles using gin(scope_ids);
alter table public.office_user_profiles enable row level security;
drop policy if exists office_user_profiles_select on public.office_user_profiles;
create policy office_user_profiles_select
on public.office_user_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.office_user_profiles oup
    where oup.auth_id = auth.uid()
  )
);
drop policy if exists office_user_profiles_update on public.office_user_profiles;
create policy office_user_profiles_update
on public.office_user_profiles
for update
to authenticated
using (
  auth.uid() = auth_id
  or exists (
    select 1
    from public.office_user_profiles oup
    where oup.auth_id = auth.uid()
      and oup.account_level in ('super_admin', 'platform_admin')
  )
)
with check (
  auth.uid() = auth_id
  or exists (
    select 1
    from public.office_user_profiles oup
    where oup.auth_id = auth.uid()
      and oup.account_level in ('super_admin', 'platform_admin')
  )
);
drop policy if exists office_user_profiles_insert on public.office_user_profiles;
create policy office_user_profiles_insert
on public.office_user_profiles
for insert
to authenticated
with check (
  exists (
    select 1
    from public.office_user_profiles oup
    where oup.auth_id = auth.uid()
      and oup.account_level in ('super_admin', 'platform_admin')
  )
);
