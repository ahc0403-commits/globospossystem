-- Migration: 256_fix_role_scope_constraints.sql
-- Fixes O-4 and O-5 from the Office closure audit (2026-04-08).

-- ── O-4: Extend account_level CHECK constraint ────────────────────────────────
--
-- Root cause: migration 065 created office_user_profiles with 6 allowed
-- account_level values. Migrations 250 (master_admin) and 251
-- (photo_objet_master, photo_objet_store_admin) introduced three additional
-- values that are used in active helper functions and RLS policies, but were
-- never added to the CHECK constraint. Any INSERT/UPDATE with these values
-- is rejected at the DB level, making master_admin and Photo Objet roles
-- impossible to assign.
--
-- Fix: drop the auto-named inline CHECK and add a named constraint with all
-- nine valid account_level values.

alter table public.office_user_profiles
  drop constraint if exists office_user_profiles_account_level_check;
alter table public.office_user_profiles
  add constraint office_user_profiles_account_level_check check (
    account_level in (
      -- Original 6 values (migration 065)
      'super_admin',
      'platform_admin',
      'office_admin',
      'brand_admin',
      'store_admin',
      'staff',
      -- Added by migration 250
      'master_admin',
      -- Added by migration 251
      'photo_objet_master',
      'photo_objet_store_admin'
    )
  );
-- ── O-5: Fix get_photo_objet_store_id() scope_type predicate ─────────────────
--
-- Root cause: migration 251 defined get_photo_objet_store_id() with
-- scope_type = 'po_store'. The scope_type CHECK constraint on
-- office_user_profiles only allows ('global', 'brand', 'store'), so no row
-- can ever have scope_type = 'po_store'. The function always returns NULL,
-- making all PO store-level RLS policies (po_sales_store, po_inventory_store,
-- po_attendance_store, po_staff_store_read, po_staff_store_write) permanently
-- non-functional for store-scoped users.
--
-- Fix: Photo Objet store-scoped users use scope_type = 'store' (the canonical
-- value) with scope_ids = [photo_objet_store_uuid]. The account_level
-- = 'photo_objet_store_admin' already distinguishes them from ops store users.
-- Change the predicate to scope_type = 'store' and add account_level guard.

create or replace function public.get_photo_objet_store_id()
returns uuid
language sql
stable
security definer
as $$
  select (scope_ids[1])::uuid
  from public.office_user_profiles
  where auth_id = auth.uid()
    and account_level = 'photo_objet_store_admin'
    and scope_type = 'store'
  limit 1;
$$;
