-- Core closure follow-up:
-- 1. Add DB-owned account issuance for superAdmin-only account creation.
-- 2. Add canonical payable status mutation for accounting.payables.
-- 3. Bind payable status writes to system.audit_log at the DB layer.

create or replace function system.issue_account(
  p_email text,
  p_password text,
  p_display_name text,
  p_account_level text,
  p_scope_type text,
  p_scope_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_user_id uuid := gen_random_uuid();
  v_email text := lower(trim(p_email));
  v_scope_ids uuid[] := coalesce(p_scope_ids, '{}'::uuid[]);
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if v_email = '' then
    raise exception 'Email is required';
  end if;

  if length(p_password) < 8 then
    raise exception 'Temporary password must be at least 8 characters';
  end if;

  if p_account_level not in (
    'staff',
    'store_admin',
    'brand_admin',
    'super_admin',
    'master_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) then
    raise exception 'Unsupported account_level %', p_account_level;
  end if;

  if p_scope_type not in ('global', 'brand', 'store') then
    raise exception 'Unsupported scope_type %', p_scope_type;
  end if;

  if p_scope_type = 'global' and coalesce(array_length(v_scope_ids, 1), 0) <> 0 then
    raise exception 'Global scope must not include scope_ids';
  end if;

  if p_scope_type in ('brand', 'store') and coalesce(array_length(v_scope_ids, 1), 0) <> 1 then
    raise exception 'Brand/store scope requires exactly one scope_id';
  end if;

  if exists (
    select 1
    from auth.users
    where lower(email) = v_email
  ) then
    raise exception 'An account with email % already exists', v_email;
  end if;

  insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    v_user_id,
    'authenticated',
    'authenticated',
    v_email,
    crypt(p_password, gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', array['email']),
    jsonb_build_object('display_name', trim(p_display_name)),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

  insert into auth.identities (
    id,
    user_id,
    provider_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    v_user_id,
    v_user_id::text,
    jsonb_build_object(
      'sub', v_user_id::text,
      'email', v_email,
      'email_verified', true
    ),
    'email',
    now(),
    now(),
    now()
  );

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
    v_user_id,
    trim(p_display_name),
    v_email,
    p_account_level,
    p_scope_type,
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
      is_active = true,
      updated_at = now();

  return v_user_id;
end;
$$;
create or replace function accounting.update_payable_status(
  payable_id uuid,
  next_status accounting.payable_status
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.payables p
      where p.id = payable_id
        and p.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.payables
  set status = next_status
  where id = payable_id;

  if not found then
    raise exception 'Payable % not found', payable_id;
  end if;
end;
$$;
create or replace function system.audit_payable_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status then
    perform system.write_audit_log(
      'payable_' || new.status,
      'payable',
      new.id,
      jsonb_build_object(
        'vendor', new.vendor,
        'store_id', new.store_id,
        'brand_id', new.brand_id,
        'old_status', old.status,
        'new_status', new.status,
        'amount', new.amount,
        'due_date', new.due_date
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_payable_status on accounting.payables;
create trigger trg_audit_payable_status
after update of status
on accounting.payables
for each row
execute function system.audit_payable_status_changes();
