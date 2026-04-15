-- Migration: 253_accounting_finance_views.sql
-- Create the two missing Office finance read views.
-- These views are required by FinanceRepository (lib/features/finance/data/finance_repository.dart)
-- which calls:
--   _client.schema('accounting').from('expenses_view')
--   _client.schema('accounting').from('purchase_requests_view')
-- Neither view existed in any prior migration.
-- See: closure audit M-1 and M-2 (2026-04-08)

-- ── expenses_view ─────────────────────────────────────────────────────────────
-- Joins ops.stores so store_name is available for Flutter display models.
-- Includes return_note for ExpenseDetail display and store_id for repo filtering.

create or replace view accounting.expenses_view as
select
  e.id,
  e.description,
  e.submitted_by,
  e.store_id,
  s.name        as store_name,
  e.amount,
  e.expense_date,
  e.status,
  e.return_note,
  e.created_at
from accounting.expenses e
left join ops.stores s on s.id = e.store_id;
alter view accounting.expenses_view set (security_invoker = true);
grant select on accounting.expenses_view to authenticated;
-- ── purchase_requests_view ────────────────────────────────────────────────────
-- Joins ops.stores for store_name and ops.brands for brand_name.
-- Includes store_id and brand_id for repo filtering.

create or replace view accounting.purchase_requests_view as
select
  pr.id,
  pr.title,
  pr.store_id,
  s.name         as store_name,
  pr.brand_id,
  b.name         as brand_name,
  pr.amount,
  pr.requested_date,
  pr.status,
  pr.created_at
from accounting.purchase_requests pr
left join ops.stores s  on s.id  = pr.store_id
left join ops.brands b  on b.id  = pr.brand_id;
alter view accounting.purchase_requests_view set (security_invoker = true);
grant select on accounting.purchase_requests_view to authenticated;
