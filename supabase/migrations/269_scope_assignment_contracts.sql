-- Scope Assignment backend contract-readiness
-- Adds a dedicated read contract and a standalone scope-only mutation.

create or replace function system.get_scope_assignment_context(account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_profile public.office_user_profiles%rowtype;
  v_scope_labels text[];
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  select *
  into v_profile
  from public.office_user_profiles
  where auth_id = account_id
     or id = account_id
  limit 1;

  if not found then
    raise exception 'Profile not found for account_id %', account_id;
  end if;

  select coalesce(array_agg(scope_label order by sort_order), '{}'::text[])
  into v_scope_labels
  from (
    select 0 as sort_order, 'Global scope'::text as scope_label
    where v_profile.scope_type = 'global'

    union all

    select 1 as sort_order, b.name::text as scope_label
    from ops.brands b
    where v_profile.scope_type = 'brand'
      and b.id = v_profile.scope_ids[1]

    union all

    select 1 as sort_order, b.name::text as scope_label
    from ops.stores s
    join ops.brands b on b.id = s.brand_id
    where v_profile.scope_type = 'store'
      and s.id = v_profile.scope_ids[1]

    union all

    select 2 as sort_order, s.name::text as scope_label
    from ops.stores s
    where v_profile.scope_type = 'store'
      and s.id = v_profile.scope_ids[1]
  ) resolved_scope;

  return jsonb_build_object(
    'account_id', v_profile.auth_id,
    'profile_id', v_profile.id,
    'display_name', v_profile.display_name,
    'email', v_profile.email,
    'account_level', v_profile.account_level,
    'scope_type', v_profile.scope_type,
    'scope_ids', coalesce(to_jsonb(v_profile.scope_ids), '[]'::jsonb),
    'current_scope_labels', to_jsonb(v_scope_labels),
    'allowed_scope_types', jsonb_build_array('global', 'brand', 'store'),
    'scope_targeting_mode', 'replace_only',
    'assignable_brands',
      (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'id', b.id,
              'name', b.name,
              'status', b.status
            )
            order by b.name
          ),
          '[]'::jsonb
        )
        from ops.brands b
      ),
    'assignable_stores',
      (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'id', s.id,
              'name', s.name,
              'brand_id', s.brand_id,
              'brand_name', b.name,
              'status', s.status
            )
            order by b.name, s.name
          ),
          '[]'::jsonb
        )
        from ops.stores s
        join ops.brands b on b.id = s.brand_id
      )
  );
end;
$$;
grant execute on function system.get_scope_assignment_context(uuid) to authenticated;
create or replace function system.assign_scope(
  account_id uuid,
  scope_type text,
  scope_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_profile public.office_user_profiles%rowtype;
  v_scope_type text := lower(trim(coalesce(scope_type, '')));
  v_scope_ids uuid[] := coalesce(scope_ids, '{}'::uuid[]);
  v_scope_count int := coalesce(array_length(v_scope_ids, 1), 0);
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  select *
  into v_profile
  from public.office_user_profiles
  where auth_id = account_id
     or id = account_id
  limit 1;

  if not found then
    raise exception 'Profile not found for account_id %', account_id;
  end if;

  if v_scope_type not in ('global', 'brand', 'store') then
    raise exception 'Unsupported scope_type %', scope_type;
  end if;

  if v_scope_type = 'global' and v_scope_count <> 0 then
    raise exception 'Global scope must not include scope_ids';
  end if;

  if v_scope_type = 'brand' and v_scope_count <> 1 then
    raise exception 'Brand scope requires exactly one brand id';
  end if;

  if v_scope_type = 'store' and v_scope_count <> 1 then
    raise exception 'Store scope requires exactly one store id';
  end if;

  if v_scope_type = 'brand' and not exists (
    select 1
    from ops.brands b
    where b.id = v_scope_ids[1]
  ) then
    raise exception 'Brand % not found', v_scope_ids[1];
  end if;

  if v_scope_type = 'store' and not exists (
    select 1
    from ops.stores s
    where s.id = v_scope_ids[1]
  ) then
    raise exception 'Store % not found', v_scope_ids[1];
  end if;

  update public.office_user_profiles
  set
    scope_type = v_scope_type,
    scope_ids = v_scope_ids,
    updated_at = now()
  where id = v_profile.id;

  if not found then
    raise exception 'Profile not found for account_id %', account_id;
  end if;
end;
$$;
grant execute on function system.assign_scope(uuid, text, uuid[]) to authenticated;
