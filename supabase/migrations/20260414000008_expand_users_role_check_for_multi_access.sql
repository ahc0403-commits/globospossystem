-- =============================================================================
-- Expand POS users role constraint for brand/store multi-access roles
-- Migration: 20260414000008_expand_users_role_check_for_multi_access.sql
-- Reason:
--   The Flutter/admin surfaces and create_staff_user function now support
--   brand_admin and store_admin, but the public.users role check constraint
--   still rejects them.
-- =============================================================================

BEGIN;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (
    role IN (
      'super_admin',
      'master_admin',
      'brand_admin',
      'store_admin',
      'admin',
      'waiter',
      'kitchen',
      'cashier',
      'photo_objet_master',
      'photo_objet_store_admin'
    )
  );

COMMIT;
