-- Migration: 252_fix_save_permissions_identity_target.sql
-- Fix: system.save_permissions was updating core.accounts (legacy table, never read
-- by auth or RLS). Identity source is public.office_user_profiles (established in
-- 065_office_user_profiles_base.sql and 200_office_user_profiles.sql).
-- This migration replaces the function to write the canonical identity fields only.
-- See: closure audit O-1 (2026-04-08)

-- Drop old overload first — CREATE OR REPLACE cannot change parameter types.
drop function if exists system.save_permissions(uuid, text, uuid, uuid);
create or replace function system.save_permissions(
  account_id   uuid,
  account_level text,
  scope_type   text,
  scope_ids    uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_account_id    alias for $1;
  v_account_level alias for $2;
  v_scope_type    alias for $3;
  v_scope_ids     alias for $4;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  update public.office_user_profiles
  set
    account_level = v_account_level,
    scope_type    = v_scope_type,
    scope_ids     = v_scope_ids,
    updated_at    = now()
  where auth_id = v_account_id;

  if not found then
    raise exception 'Profile not found for account_id %', v_account_id;
  end if;
end;
$$;
