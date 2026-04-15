create or replace view dashboard.operations_report_rows_view as
with role_ctx as (
  select
    core.current_role() as role_name,
    core.current_brand_id() as brand_id,
    core.current_store_id() as store_id
)
select
  'payroll'::text as module,
  opr.id as item_id,
  ('Payroll review · ' ||
    to_char(opr.period_start, 'DD Mon YYYY') ||
    ' - ' ||
    to_char(opr.period_end, 'DD Mon YYYY'))::text as item_label,
  opr.brand_id as scope_brand_id,
  opr.restaurant_id as scope_store_id,
  coalesce(s.name, 'Store payroll')::text as scope_label,
  opr.status::text as status_raw,
  'pending_review'::text as status_bucket,
  opr.updated_at as date_value,
  ('Period ' ||
    to_char(opr.period_start, 'DD Mon') ||
    ' - ' ||
    to_char(opr.period_end, 'DD Mon YYYY'))::text as date_label,
  ('/hr/payroll/detail?id=' || opr.source_payroll_id)::text as detail_route,
  'Open payroll record'::text as detail_route_label
from public.office_payroll_reviews opr
left join ops.stores s on s.id = opr.restaurant_id
cross join role_ctx
where opr.status in ('pending', 'in_review')
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and opr.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and opr.restaurant_id = role_ctx.store_id
    )
  )

union all

select
  'quality'::text as module,
  qc.id as item_id,
  qc.title::text as item_label,
  st.brand_id as scope_brand_id,
  qc.store_id as scope_store_id,
  coalesce(st.name, 'Store quality')::text as scope_label,
  qc.status::text as status_raw,
  'needs_attention'::text as status_bucket,
  qc.created_at as date_value,
  coalesce(nullif(qc.period, ''), to_char(qc.created_at, 'DD Mon YYYY'))::text
    as date_label,
  ('/ops/quality/detail?id=' || qc.id)::text as detail_route,
  'Open quality check'::text as detail_route_label
from ops.quality_checks qc
left join ops.stores st on st.id = qc.store_id
cross join role_ctx
where qc.status in ('pending', 'issue')
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and st.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and qc.store_id = role_ctx.store_id
    )
  )

union all

select
  'expense'::text as module,
  e.id as item_id,
  e.description::text as item_label,
  e.brand_id as scope_brand_id,
  e.store_id as scope_store_id,
  coalesce(e.store_name, 'Store expense')::text as scope_label,
  e.status::text as status_raw,
  'pending_approval'::text as status_bucket,
  e.expense_date::timestamptz as date_value,
  to_char(e.expense_date, 'DD Mon YYYY')::text as date_label,
  ('/accounting/detail?id=' || e.id || '&type=expense')::text as detail_route,
  'Open expense detail'::text as detail_route_label
from accounting.expenses_view e
cross join role_ctx
where e.status = 'pending'
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and e.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and e.store_id = role_ctx.store_id
    )
  )

union all

select
  'purchase'::text as module,
  p.id as item_id,
  p.title::text as item_label,
  p.brand_id as scope_brand_id,
  p.store_id as scope_store_id,
  coalesce(p.store_name, 'Store purchase')::text as scope_label,
  p.status::text as status_raw,
  'pending_approval'::text as status_bucket,
  p.requested_date::timestamptz as date_value,
  to_char(p.requested_date, 'DD Mon YYYY')::text as date_label,
  ('/accounting/purchase-approvals/detail?id=' || p.id)::text as detail_route,
  'Open purchase detail'::text as detail_route_label
from accounting.purchase_requests_view p
cross join role_ctx
where p.status = 'pending_approval'
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and p.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and p.store_id = role_ctx.store_id
    )
  )

union all

select
  'document_reference'::text as module,
  d.id as item_id,
  d.title::text as item_label,
  d.brand_id as scope_brand_id,
  null::uuid as scope_store_id,
  case d.scope
    when 'company' then 'Company reference'
    when 'brand' then coalesce(b.name, 'Brand reference')
    when 'store' then 'Store reference'
    else 'Document reference'
  end::text as scope_label,
  d.status::text as status_raw,
  'reference_active'::text as status_bucket,
  d.updated_at as date_value,
  to_char(d.updated_at, 'DD Mon YYYY')::text as date_label,
  ('/documents/detail?id=' || d.id)::text as detail_route,
  'Open document'::text as detail_route_label
from documents.documents d
left join ops.brands b on b.id = d.brand_id
where d.status = 'active';
alter view dashboard.operations_report_rows_view set (security_invoker = true);
grant select on dashboard.operations_report_rows_view to authenticated;
