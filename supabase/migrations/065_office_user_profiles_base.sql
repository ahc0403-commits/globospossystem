-- Base table required by 070_helper_functions.sql
-- Keep full RLS/policy setup in 200_office_user_profiles.sql.

create table if not exists public.office_user_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid not null references auth.users(id) unique,
  company_id uuid null,
  account_level text not null check (
    account_level in (
      'super_admin',
      'platform_admin',
      'office_admin',
      'brand_admin',
      'store_admin',
      'staff'
    )
  ),
  domain_authorities jsonb default '[]',
  scope_type text not null default 'global' check (
    scope_type in ('global', 'brand', 'store')
  ),
  scope_ids uuid[] default '{}',
  display_name text not null,
  email text,
  is_active boolean default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
