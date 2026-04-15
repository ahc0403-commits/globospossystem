-- 291_add_missing_fk_indexes.sql
-- Add missing indexes on FK and filter columns that the app queries frequently.
-- All columns verified to exist against production schema on 2026-04-13.
-- Resolves harness findings E3-01..E3-06.
--
-- Postgres does not auto-index FK columns, so without these the planner does
-- sequential scans for brand/store joins and date-filtered queries. These add
-- ordinary btree indexes that are safe to apply online.

BEGIN;
-- ops.stores
CREATE INDEX IF NOT EXISTS idx_stores_brand ON ops.stores(brand_id);
-- hr.employees
CREATE INDEX IF NOT EXISTS idx_employees_store ON hr.employees(store_id);
CREATE INDEX IF NOT EXISTS idx_employees_brand ON hr.employees(brand_id);
-- hr.payroll_records
CREATE INDEX IF NOT EXISTS idx_payroll_store ON hr.payroll_records(store_id);
CREATE INDEX IF NOT EXISTS idx_payroll_period ON hr.payroll_records(period_date DESC);
-- ops.quality_checks
CREATE INDEX IF NOT EXISTS idx_qc_store ON ops.quality_checks(store_id);
CREATE INDEX IF NOT EXISTS idx_qc_created ON ops.quality_checks(created_at DESC);
-- accounting.purchase_requests
CREATE INDEX IF NOT EXISTS idx_pr_brand ON accounting.purchase_requests(brand_id);
CREATE INDEX IF NOT EXISTS idx_pr_store ON accounting.purchase_requests(store_id);
-- accounting.expenses
CREATE INDEX IF NOT EXISTS idx_expenses_store ON accounting.expenses(store_id);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON accounting.expenses(expense_date DESC);
-- documents.documents
CREATE INDEX IF NOT EXISTS idx_docs_brand ON documents.documents(brand_id);
-- documents.document_versions
CREATE INDEX IF NOT EXISTS idx_docver_doc ON documents.document_versions(document_id);
COMMIT;
