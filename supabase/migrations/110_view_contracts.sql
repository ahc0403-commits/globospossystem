create or replace view ops.brand_store_view as
select
  b.id,
  b.name,
  b.status,
  count(s.id)::int as store_count
from ops.brands b
left join ops.stores s on s.brand_id = b.id
group by b.id, b.name, b.status;
create or replace view ops.brand_detail_view as
select
  b.id as brand_id,
  b.name as brand_name,
  b.status as brand_status,
  b.region,
  b.currency,
  b.tax_scheme,
  b.created_at as brand_created_at,
  s.id as store_id,
  s.name as store_name,
  s.status as store_status
from ops.brands b
left join ops.stores s on s.brand_id = b.id;
create or replace view hr.employee_detail_view as
select
  e.id as employee_id,
  e.name as employee_name,
  e.status as employee_status,
  e.role as employee_role,
  s.id as store_id,
  s.name as store_name,
  b.id as brand_id,
  b.name as brand_name,
  e.email,
  e.phone,
  e.start_date,
  e.employment_type,
  pr.period_date as last_period_date,
  pr.net_pay as last_net_pay
from hr.employees e
left join ops.stores s on s.id = e.store_id
left join ops.brands b on b.id = e.brand_id
left join lateral (
  select pr.period_date, pr.net_pay
  from hr.payroll_records pr
  where pr.employee_id = e.id
  order by pr.period_date desc nulls last
  limit 1
) pr on true;
create or replace view documents.document_detail_view as
select
  d.id as document_id,
  d.title,
  d.category,
  d.scope,
  d.updated_at,
  d.version as document_version,
  d.status,
  d.is_pinned,
  d.brand_id,
  d.visibility,
  v.id as version_id,
  v.version as version_label,
  v.created_at as version_created_at,
  v.note as version_note
from documents.documents d
left join documents.document_versions v on v.document_id = d.id;
create or replace view dashboard.dashboard_summary_view as
with role_ctx as (
  select
    core.current_role() as role_name,
    core.current_brand_id() as brand_id,
    core.current_store_id() as store_id
)
select
  case
    when role_ctx.role_name = 'superAdmin' then (select count(*) from ops.brands)
    when role_ctx.role_name = 'brandManager' then (select count(*) from ops.brands where id = role_ctx.brand_id)
    else (select count(*) from ops.brands where id = role_ctx.brand_id)
  end as brand_count,
  case
    when role_ctx.role_name = 'superAdmin' then (select count(*) from ops.stores)
    when role_ctx.role_name = 'brandManager' then (select count(*) from ops.stores where brand_id = role_ctx.brand_id)
    else (select count(*) from ops.stores where id = role_ctx.store_id)
  end as store_count,
  case
    when role_ctx.role_name = 'superAdmin' then (select count(*) from hr.employees)
    when role_ctx.role_name = 'brandManager' then (select count(*) from hr.employees where brand_id = role_ctx.brand_id)
    else (select count(*) from hr.employees where store_id = role_ctx.store_id)
  end as employee_count,
  case
    when role_ctx.role_name = 'superAdmin' then (
      (select count(*) from hr.payroll_records where status in ('pending', 'in_review')) +
      (select count(*) from ops.quality_checks where status in ('pending', 'issue')) +
      (select count(*) from accounting.expenses where status = 'pending') +
      (select count(*) from accounting.purchase_requests where status = 'pending_approval')
    )
    when role_ctx.role_name = 'brandManager' then (
      (select count(*) from hr.payroll_records pr where pr.status in ('pending', 'in_review') and pr.brand_id = role_ctx.brand_id) +
      (select count(*)
       from ops.quality_checks qc
       join ops.stores s on s.id = qc.store_id
       where qc.status in ('pending', 'issue')
         and s.brand_id = role_ctx.brand_id) +
      (select count(*)
       from accounting.expenses e
       join ops.stores s on s.id = e.store_id
       where e.status = 'pending'
         and s.brand_id = role_ctx.brand_id) +
      (select count(*)
       from accounting.purchase_requests pr
       where pr.status = 'pending_approval'
         and pr.brand_id = role_ctx.brand_id)
    )
    else (
      (select count(*) from hr.payroll_records where status in ('pending', 'in_review') and store_id = role_ctx.store_id) +
      (select count(*) from ops.quality_checks where status in ('pending', 'issue') and store_id = role_ctx.store_id) +
      (select count(*) from accounting.expenses where status = 'pending' and store_id = role_ctx.store_id) +
      (select count(*) from accounting.purchase_requests where status = 'pending_approval' and store_id = role_ctx.store_id)
    )
  end as pending_items
from role_ctx;
