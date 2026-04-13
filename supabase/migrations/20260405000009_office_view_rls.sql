-- Office integration Phase 1: Scope-based access control functions

create or replace function public.office_get_accessible_store_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_scope_type text;
  v_scope_ids uuid[];
  v_store_ids uuid[];
begin
  select scope_type, scope_ids
    into v_scope_type, v_scope_ids
  from public.office_user_profiles
  where auth_id = auth.uid()
  limit 1;

  if v_scope_type is null then
    return array[]::uuid[];
  end if;

  if v_scope_type = 'global' then
    select array_agg(r.id) into v_store_ids
    from public.restaurants r;
    return coalesce(v_store_ids, array[]::uuid[]);
  end if;

  if v_scope_type = 'brand' then
    select array_agg(r.id) into v_store_ids
    from public.restaurants r
    where r.brand_id = any(v_scope_ids);
    return coalesce(v_store_ids, array[]::uuid[]);
  end if;

  return coalesce(v_scope_ids, array[]::uuid[]);
end;
$$;

create or replace function public.office_get_accessible_brand_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_scope_type text;
  v_scope_ids uuid[];
  v_brand_ids uuid[];
begin
  select scope_type, scope_ids
    into v_scope_type, v_scope_ids
  from public.office_user_profiles
  where auth_id = auth.uid()
  limit 1;

  if v_scope_type is null then
    return array[]::uuid[];
  end if;

  if v_scope_type = 'global' then
    select array_agg(b.id) into v_brand_ids
    from public.brands b;
    return coalesce(v_brand_ids, array[]::uuid[]);
  end if;

  if v_scope_type = 'brand' then
    return coalesce(v_scope_ids, array[]::uuid[]);
  end if;

  select array_agg(distinct r.brand_id) into v_brand_ids
  from public.restaurants r
  where r.id = any(v_scope_ids);

  return coalesce(v_brand_ids, array[]::uuid[]);
end;
$$;
