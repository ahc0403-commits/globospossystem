-- Priority 1 Office security remediation (2026-04-08 audit)
-- Covers: CRIT-1, CRIT-2, CRIT-3, CRIT-5, CRIT-6

create or replace function public.freeze_office_profile_sensitive_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_office_account_level() not in ('super_admin', 'platform_admin') then
    new.account_level = old.account_level;
    new.scope_type = old.scope_type;
    new.scope_ids = old.scope_ids;
    new.is_active = old.is_active;
    new.domain_authorities = old.domain_authorities;
  end if;

  new.updated_at = now();

  return new;
end;
$$;
drop trigger if exists freeze_office_profile_sensitive_fields_before_update
on public.office_user_profiles;
create trigger freeze_office_profile_sensitive_fields_before_update
before update on public.office_user_profiles
for each row
execute function public.freeze_office_profile_sensitive_fields();
create or replace function public.handle_new_office_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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
    'staff',
    'store',
    '{}'::uuid[],
    true
  )
  on conflict (auth_id) do update
    set
      display_name = excluded.display_name,
      email = excluded.email,
      updated_at = now();

  return new;
end;
$$;
drop policy if exists document_versions_select on documents.document_versions;
create policy document_versions_select on documents.document_versions
  for select
  using (
    exists (
      select 1
      from documents.documents d
      where d.id = document_versions.document_id
        and (
          d.visibility = 'all'
          or core.current_role() = 'superAdmin'
          or (d.visibility = 'brand' and d.brand_id = core.current_brand_id())
          or (d.visibility = 'admin' and core.current_role() in ('superAdmin', 'brandManager'))
          or (d.visibility = 'store' and core.current_store_id() is not null)
        )
    )
  );
drop policy if exists accounting_entries_select on accounting.accounting_entries;
create policy accounting_entries_select on accounting.accounting_entries
  for select
  using (core.current_role() = 'superAdmin');
