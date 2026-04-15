create or replace view dashboard.exception_report_rows_view as
with role_ctx as (
  select
    core.current_role() as role_name,
    core.current_brand_id() as brand_id,
    core.current_store_id() as store_id
)
select
  'payroll_exception'::text as exception_type,
  pr.id as entity_id,
  (pr.employee_name || ' · ' || to_char(pr.period_date, 'DD Mon YYYY'))::text
    as entity_label,
  pr.brand_id as scope_brand_id,
  pr.store_id as scope_store_id,
  coalesce(s.name, 'Store payroll')::text as scope_label,
  pr.status::text as status_raw,
  'action_required'::text as status_bucket,
  pr.period_date::timestamptz as date_value,
  to_char(pr.period_date, 'DD Mon YYYY')::text as date_label,
  ('/hr/payroll/detail?id=' || pr.id)::text as detail_route,
  'Open payroll record'::text as detail_route_label
from hr.payroll_records pr
left join ops.stores s on s.id = pr.store_id
cross join role_ctx
where pr.has_exception = true
  and pr.status in ('pending', 'in_review')
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and pr.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and pr.store_id = role_ctx.store_id
    )
  )

union all

select
  'quality_issue'::text as exception_type,
  qc.id as entity_id,
  qc.title::text as entity_label,
  s.brand_id as scope_brand_id,
  qc.store_id as scope_store_id,
  coalesce(s.name, 'Store quality')::text as scope_label,
  qc.status::text as status_raw,
  'action_required'::text as status_bucket,
  qc.created_at as date_value,
  coalesce(nullif(qc.period, ''), to_char(qc.created_at, 'DD Mon YYYY'))::text
    as date_label,
  ('/ops/quality/detail?id=' || qc.id)::text as detail_route,
  'Open quality check'::text as detail_route_label
from ops.quality_checks qc
left join ops.stores s on s.id = qc.store_id
cross join role_ctx
where qc.status = 'issue'
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and s.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and qc.store_id = role_ctx.store_id
    )
  )

union all

select
  'quality_missing_evidence'::text as exception_type,
  qc.id as entity_id,
  qc.title::text as entity_label,
  s.brand_id as scope_brand_id,
  qc.store_id as scope_store_id,
  coalesce(s.name, 'Store quality')::text as scope_label,
  qc.evidence_state::text as status_raw,
  'action_required'::text as status_bucket,
  qc.created_at as date_value,
  coalesce(nullif(qc.period, ''), to_char(qc.created_at, 'DD Mon YYYY'))::text
    as date_label,
  ('/ops/quality/detail?id=' || qc.id)::text as detail_route,
  'Open quality check'::text as detail_route_label
from ops.quality_checks qc
left join ops.stores s on s.id = qc.store_id
cross join role_ctx
where qc.evidence_state = 'missing'
  and qc.status <> 'resolved'
  and qc.status <> 'issue'
  and (
    role_ctx.role_name = 'superAdmin'
    or (
      role_ctx.role_name = 'brandManager'
      and s.brand_id = role_ctx.brand_id
    )
    or (
      role_ctx.role_name not in ('superAdmin', 'brandManager')
      and qc.store_id = role_ctx.store_id
    )
  );
alter view dashboard.exception_report_rows_view set (security_invoker = true);
grant select on dashboard.exception_report_rows_view to authenticated;
