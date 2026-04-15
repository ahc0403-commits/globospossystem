-- System Settings backend contract-readiness
-- Narrow bounded model: global in-app notification generation policy.

create table if not exists system.system_settings (
  settings_key text primary key
    check (settings_key = 'global'),
  payroll_confirmation_in_app_notifications_enabled boolean not null default true,
  document_release_in_app_notifications_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table system.system_settings enable row level security;
insert into system.system_settings (
  settings_key,
  payroll_confirmation_in_app_notifications_enabled,
  document_release_in_app_notifications_enabled
)
values (
  'global',
  true,
  true
)
on conflict (settings_key) do nothing;
create or replace function system.get_system_settings()
returns jsonb
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_settings system.system_settings%rowtype;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  select *
  into v_settings
  from system.system_settings
  where settings_key = 'global';

  if not found then
    raise exception 'System settings row is missing';
  end if;

  return jsonb_build_object(
    'supported_keys',
    jsonb_build_array(
      'payroll_confirmation_in_app_notifications_enabled',
      'document_release_in_app_notifications_enabled'
    ),
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled
  );
end;
$$;
grant execute on function system.get_system_settings() to authenticated;
create or replace function system.update_system_settings(settings_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_allowed_keys constant text[] := array[
    'payroll_confirmation_in_app_notifications_enabled',
    'document_release_in_app_notifications_enabled'
  ];
  v_key text;
  v_invalid_keys text[];
  v_settings system.system_settings%rowtype;
  v_old_values jsonb;
  v_new_values jsonb;
  v_changed_keys text[] := '{}';
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if settings_patch is null or jsonb_typeof(settings_patch) <> 'object' then
    raise exception 'settings_patch must be a JSON object';
  end if;

  select array_agg(key order by key)
  into v_invalid_keys
  from jsonb_object_keys(settings_patch) as key
  where key <> all(v_allowed_keys);

  if coalesce(array_length(v_invalid_keys, 1), 0) > 0 then
    raise exception 'Unsupported system settings key(s): %', array_to_string(v_invalid_keys, ', ');
  end if;

  if not (settings_patch ? 'payroll_confirmation_in_app_notifications_enabled')
     and not (settings_patch ? 'document_release_in_app_notifications_enabled') then
    raise exception 'No supported system settings keys were provided';
  end if;

  if settings_patch ? 'payroll_confirmation_in_app_notifications_enabled' then
    if jsonb_typeof(settings_patch -> 'payroll_confirmation_in_app_notifications_enabled') <> 'boolean' then
      raise exception
        'payroll_confirmation_in_app_notifications_enabled must be a boolean';
    end if;
  end if;

  if settings_patch ? 'document_release_in_app_notifications_enabled' then
    if jsonb_typeof(settings_patch -> 'document_release_in_app_notifications_enabled') <> 'boolean' then
      raise exception
        'document_release_in_app_notifications_enabled must be a boolean';
    end if;
  end if;

  select *
  into v_settings
  from system.system_settings
  where settings_key = 'global'
  for update;

  if not found then
    raise exception 'System settings row is missing';
  end if;

  v_old_values := jsonb_build_object(
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled
  );

  if settings_patch ? 'payroll_confirmation_in_app_notifications_enabled' then
    if v_settings.payroll_confirmation_in_app_notifications_enabled is distinct from
       (settings_patch ->> 'payroll_confirmation_in_app_notifications_enabled')::boolean then
      v_changed_keys := array_append(
        v_changed_keys,
        'payroll_confirmation_in_app_notifications_enabled'
      );
    end if;

    v_settings.payroll_confirmation_in_app_notifications_enabled :=
      (settings_patch ->> 'payroll_confirmation_in_app_notifications_enabled')::boolean;
  end if;

  if settings_patch ? 'document_release_in_app_notifications_enabled' then
    if v_settings.document_release_in_app_notifications_enabled is distinct from
       (settings_patch ->> 'document_release_in_app_notifications_enabled')::boolean then
      v_changed_keys := array_append(
        v_changed_keys,
        'document_release_in_app_notifications_enabled'
      );
    end if;

    v_settings.document_release_in_app_notifications_enabled :=
      (settings_patch ->> 'document_release_in_app_notifications_enabled')::boolean;
  end if;

  update system.system_settings
  set
    payroll_confirmation_in_app_notifications_enabled =
      v_settings.payroll_confirmation_in_app_notifications_enabled,
    document_release_in_app_notifications_enabled =
      v_settings.document_release_in_app_notifications_enabled,
    updated_at = now()
  where settings_key = 'global';

  v_new_values := jsonb_build_object(
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled
  );

  perform system.write_audit_log(
    'system_settings_updated',
    'system_settings',
    null,
    jsonb_build_object(
      'settings_key', 'global',
      'update_mode', 'partial_patch',
      'changed_keys', to_jsonb(v_changed_keys),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  return v_new_values;
end;
$$;
grant execute on function system.update_system_settings(jsonb) to authenticated;
create or replace function system.notify_payroll_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_enabled boolean;
begin
  select payroll_confirmation_in_app_notifications_enabled
  into v_enabled
  from system.system_settings
  where settings_key = 'global';

  if not coalesce(v_enabled, true) then
    return new;
  end if;

  if new.status = 'confirmed' and (old.status is null or old.status != 'confirmed') then
    insert into system.notifications (recipient_id, type, title, entity_type, entity_id)
    select oup.auth_id,
           'payroll_confirmed',
           'Payroll record confirmed',
           'payroll',
           new.id
    from public.office_user_profiles oup
    where oup.account_level in ('super_admin', 'brand_admin')
      and oup.is_active = true;
  end if;
  return new;
end;
$$;
create or replace function system.notify_document_released()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_enabled boolean;
begin
  select document_release_in_app_notifications_enabled
  into v_enabled
  from system.system_settings
  where settings_key = 'global';

  if not coalesce(v_enabled, true) then
    return new;
  end if;

  if new.status = 'active' and (old.status is null or old.status != 'active') then
    insert into system.notifications (recipient_id, type, title, entity_type, entity_id)
    select oup.auth_id,
           'document_released',
           'Document released: ' || new.title,
           'document',
           new.id
    from public.office_user_profiles oup
    where oup.is_active = true;
  end if;
  return new;
end;
$$;
