-- Break RLS recursion by making scope helper functions SECURITY DEFINER.
-- These helpers are used by many policies; they must read scope source tables
-- without recursively re-entering RLS policies.

create or replace function core.current_role()
returns text
language sql
stable
security definer
set search_path = core, public
as $$
  select case oup.account_level
    when 'super_admin' then 'superAdmin'
    when 'platform_admin' then 'superAdmin'
    when 'office_admin' then 'brandManager'
    when 'brand_admin' then 'brandManager'
    when 'store_admin' then 'storeManager'
    when 'staff' then 'staff'
    else 'staff'
  end
  from public.office_user_profiles oup
  where oup.auth_id = auth.uid()
  limit 1;
$$;
create or replace function core.current_account_id()
returns uuid
language sql
stable
security definer
set search_path = core, public
as $$
  select auth.uid();
$$;
create or replace function core.current_brand_id()
returns uuid
language sql
stable
security definer
set search_path = core, public, ops
as $$
  select case oup.scope_type
    when 'global' then null
    when 'brand' then oup.scope_ids[1]
    when 'store' then (
      select s.brand_id from ops.stores s where s.id = oup.scope_ids[1]
    )
    else null
  end
  from public.office_user_profiles oup
  where oup.auth_id = auth.uid()
  limit 1;
$$;
create or replace function core.current_store_id()
returns uuid
language sql
stable
security definer
set search_path = core, public
as $$
  select case oup.scope_type
    when 'store' then oup.scope_ids[1]
    else null
  end
  from public.office_user_profiles oup
  where oup.auth_id = auth.uid()
  limit 1;
$$;
