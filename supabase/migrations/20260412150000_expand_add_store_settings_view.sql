-- Phase 2 Step 2 — fill the gap left by the Expand migration
-- Adds the store_settings alias view that should have been created
-- alongside the stores / public_store_profiles aliases.
--
-- This view exposes restaurant_settings.restaurant_id as store_id so
-- future Dart queries can read the new column name without touching
-- the underlying physical table.

CREATE OR REPLACE VIEW public.store_settings AS
SELECT
  id,
  restaurant_id AS store_id,
  payroll_pin,
  settings_json,
  updated_at
FROM public.restaurant_settings;
