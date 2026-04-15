-- Fixes:
-- 1) auth.users -> office_user_profiles trigger type mismatch (jsonb -> uuid[])
-- 2) office_user_profiles RLS infinite recursion
-- 3) PostgREST schema exposure for non-public schemas

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

create or replace function public.handle_new_office_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope_ids uuid[] := '{}'::uuid[];
begin
  if jsonb_typeof(new.raw_user_meta_data -> 'scope_ids') = 'array' then
    select coalesce(array_agg(x::uuid), '{}'::uuid[])
      into v_scope_ids
    from jsonb_array_elements_text(new.raw_user_meta_data -> 'scope_ids') as t(x);
  end if;

  insert into public.office_user_profiles (
    auth_id,
    display_name,
    email,
    account_level,
    scope_type,
    scope_ids,
    is_active
  )
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1)
    ),
    new.email,
    coalesce(new.raw_user_meta_data ->> 'account_level', 'staff'),
    coalesce(new.raw_user_meta_data ->> 'scope_type', 'store'),
    v_scope_ids,
    true
  )
  on conflict (auth_id) do update
    set
      display_name = excluded.display_name,
      email = excluded.email,
      account_level = excluded.account_level,
      scope_type = excluded.scope_type,
      scope_ids = excluded.scope_ids,
      updated_at = now();

  return new;
end;
$$;
create or replace function public.current_office_account_level()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select oup.account_level
  from public.office_user_profiles oup
  where oup.auth_id = auth.uid()
  limit 1;
$$;
drop policy if exists office_user_profiles_select on public.office_user_profiles;
drop policy if exists office_user_profiles_update on public.office_user_profiles;
drop policy if exists office_user_profiles_insert on public.office_user_profiles;
create policy office_user_profiles_select
on public.office_user_profiles
for select
to authenticated
using (
  auth.uid() = auth_id
  or public.current_office_account_level() in ('super_admin', 'platform_admin')
);
create policy office_user_profiles_update
on public.office_user_profiles
for update
to authenticated
using (
  auth.uid() = auth_id
  or public.current_office_account_level() in ('super_admin', 'platform_admin')
)
with check (
  auth.uid() = auth_id
  or public.current_office_account_level() in ('super_admin', 'platform_admin')
);
create policy office_user_profiles_insert
on public.office_user_profiles
for insert
to authenticated
with check (
  public.current_office_account_level() in ('super_admin', 'platform_admin')
);
alter role authenticator
set pgrst.db_schemas to 'public,core,hr,ops,accounting,documents,dashboard,system';
notify pgrst, 'reload config';
