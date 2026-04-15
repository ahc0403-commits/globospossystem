-- Migration: 257_fix_update_account_status.sql
-- Fixes R-1 from the Office closure audit (2026-04-08).
--
-- Root cause: system.update_account_status (migration 080) updates
-- core.accounts.status, a legacy table that is not the canonical identity
-- source. The canonical identity table is public.office_user_profiles.
-- The active Flutter path (account_repository.dart updateAccountStatus)
-- already bypasses this RPC and writes directly to office_user_profiles.is_active,
-- but the RPC body remains a dead wrong-target write.
--
-- Fix: rewrite the function to update public.office_user_profiles.is_active
-- and updated_at, matching the canonical direct-write path in Flutter.
-- Authorization guard (superAdmin only) and SECURITY DEFINER are preserved.
-- Parameter names and schema binding are unchanged so any future RPC caller
-- requires no signature update.

create or replace function system.update_account_status(
  account_id uuid,
  active     boolean
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  update public.office_user_profiles
  set
    is_active  = active,
    updated_at = now()
  where auth_id = account_id;

  if not found then
    raise exception 'Profile not found for account_id %', account_id;
  end if;
end;
$$;
