-- ============================================================
-- Emergency Cleanup: Drop broken Office-side remote residue
-- 2026-04-09
--
-- Context: Office-side objects were applied directly to this shared
-- Supabase project outside the POS migration chain. After migration
-- 20260409000012 dropped office_user_profiles, these objects became
-- broken and pose a POS runtime risk.
--
-- CRITICAL: 12 office_read_* policies on POS-core tables call
-- get_caller_type(), which references the dropped office_user_profiles
-- table and errors at runtime.
--
-- PROTECTED (not touched):
--   - office_payroll_reviews (table)
--   - office_confirm_payroll() (RPC)
--   - office_return_payroll() (RPC)
--   - on_payroll_store_submitted() (trigger function)
--   - trg_payroll_store_submitted (trigger)
--
-- Evidence: Zero POS repo references to any dropped object (grep confirmed)
-- ============================================================

BEGIN;
-- ============================================================
-- STEP 1: Drop 12 broken office_read_* policies on POS-core tables
-- These call get_caller_type() which errors on dropped office_user_profiles
-- ============================================================

DROP POLICY IF EXISTS office_read_attendance ON attendance_logs;
DROP POLICY IF EXISTS office_read_external_sales ON external_sales;
DROP POLICY IF EXISTS office_read_inventory ON inventory_items;
DROP POLICY IF EXISTS office_read_menu_items ON menu_items;
DROP POLICY IF EXISTS office_read_orders ON orders;
DROP POLICY IF EXISTS office_read_payments ON payments;
DROP POLICY IF EXISTS office_read_payroll ON payroll_records;
DROP POLICY IF EXISTS office_read_qc ON qc_checks;
DROP POLICY IF EXISTS office_read_qc_templates ON qc_templates;
DROP POLICY IF EXISTS office_read_restaurants ON restaurants;
DROP POLICY IF EXISTS office_read_wage_configs ON staff_wage_configs;
DROP POLICY IF EXISTS office_read_users ON users;
-- ============================================================
-- STEP 2: Drop office-only tables (CASCADE drops their policies too)
-- Must happen BEFORE dropping get_caller_type() because these tables'
-- policies depend on that function. CASCADE auto-removes the policies.
-- Zero POS repo references, zero Dart dependencies.
-- ============================================================

DROP TABLE IF EXISTS office_accounting_entries CASCADE;
DROP TABLE IF EXISTS office_document_versions CASCADE;
DROP TABLE IF EXISTS office_documents CASCADE;
DROP TABLE IF EXISTS office_expenses CASCADE;
DROP TABLE IF EXISTS office_payables CASCADE;
-- ============================================================
-- STEP 3: Drop broken get_caller_type() function
-- References dropped office_user_profiles, confirmed error at runtime.
-- All dependent policies were removed in Steps 1 & 2.
-- ============================================================

DROP FUNCTION IF EXISTS get_caller_type();
-- ============================================================
-- STEP 4: Drop broken office_current_* functions
-- All reference dropped office_user_profiles in their body
-- ============================================================

DROP FUNCTION IF EXISTS office_current_role();
DROP FUNCTION IF EXISTS office_current_brand_id();
DROP FUNCTION IF EXISTS office_current_store_id();
-- ============================================================
-- STEP 5: Drop broken office identity/permission functions
-- Reference dropped office_user_profiles
-- ============================================================

DROP FUNCTION IF EXISTS office_create_account(text, text, text, text, text, uuid[], jsonb);
DROP FUNCTION IF EXISTS office_save_permissions(uuid, text, text, uuid[], jsonb);
-- ============================================================
-- STEP 6: Drop broken office purchase functions
-- Reference dropped office_purchases table
-- ============================================================

DROP FUNCTION IF EXISTS office_approve_purchase(uuid);
DROP FUNCTION IF EXISTS office_reject_purchase(uuid);
-- ============================================================
-- STEP 7: Drop intact but dead office domain functions
-- Zero POS dependency, belong to Office system
-- ============================================================

DROP FUNCTION IF EXISTS office_approve_expense(uuid);
DROP FUNCTION IF EXISTS office_reject_payroll(uuid);
DROP FUNCTION IF EXISTS office_release_document(uuid);
DROP FUNCTION IF EXISTS office_return_expense(uuid, text);
COMMIT;
