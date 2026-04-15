-- Migration: 255_expenses_view_add_brand_id.sql
-- Add brand_id to accounting.expenses_view so Flutter RecordScope.brand
-- can be populated for expense records.
--
-- Root cause: migration 253 joined ops.stores for store_name but did not
-- select s.brand_id. As a result, finance_detail_page.dart could not
-- derive brand scope for brandManager checks on expense records.
--
-- Fix: rebuild the view with s.brand_id included.
-- The ops.stores join is already present; no additional join is required.
-- All columns required by existing Flutter models are preserved.

drop view if exists accounting.expenses_view;

create or replace view accounting.expenses_view as
select
  e.id,
  e.description,
  e.submitted_by,
  e.store_id,
  s.name        as store_name,
  s.brand_id,
  e.amount,
  e.expense_date,
  e.status,
  e.return_note,
  e.created_at
from accounting.expenses e
left join ops.stores s on s.id = e.store_id;
alter view accounting.expenses_view set (security_invoker = true);
grant select on accounting.expenses_view to authenticated;
