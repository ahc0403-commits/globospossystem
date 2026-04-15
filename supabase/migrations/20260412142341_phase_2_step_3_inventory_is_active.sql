-- Phase 2 Step 3 (C-01 partial fix): add inventory_items.is_active
-- Scope v1.3 Section 12 — Phase 2 Step 3
--
-- The other half of C-01 (payroll_records.updated_at) was found to
-- already exist in the live DB, so this migration only adds the
-- inventory_items.is_active column.
--
-- Backfill: existing rows default to true (active).
-- Compatibility: 20260412170000_fix_inventory_is_active_in_daily_closing.sql
-- contains a workaround that filters without is_active. After this
-- migration, that workaround becomes a no-op (still correct, just
-- stale comments). Do not remove it in this commit.

ALTER TABLE public.inventory_items
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.inventory_items.is_active IS
  'Soft-delete / deactivation flag. Default true. Phase 2 Step 3 (C-01).';;
