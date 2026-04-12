-- =============================================================================
-- Phase 2 Step 4 — ROLLBACK (manual apply only, NOT in migration chain)
-- File: 20260412190001_rollback_phase_2_step_4_wetax_tables.sql
-- Reverses: 20260412190000_phase_2_step_4_wetax_tables.sql
-- Apply only if Step 4 must be undone. Reverse dependency order.
-- WARNING: This drops all 11 tables and the 4 system_config seed rows.
--          Any data inserted after Step 4 will be permanently lost.
-- =============================================================================

BEGIN;

-- Reverse dependency order (leaves first, roots last)
DROP TABLE IF EXISTS public.partner_credential_access_log;
DROP TABLE IF EXISTS public.einvoice_events;
DROP TABLE IF EXISTS public.einvoice_jobs;
DROP TABLE IF EXISTS public.store_tax_entity_history;
DROP TABLE IF EXISTS public.b2b_buyer_cache;
DROP TABLE IF EXISTS public.system_config;
DROP TABLE IF EXISTS public.wetax_reference_values;
DROP TABLE IF EXISTS public.partner_credentials;
DROP TABLE IF EXISTS public.einvoice_shop;
DROP TABLE IF EXISTS public.tax_entity;
DROP TABLE IF EXISTS public.brand_master;

COMMIT;
