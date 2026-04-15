drop view if exists dashboard.dashboard_summary_view;
create view dashboard.dashboard_summary_view as
with role_ctx as (
  select
    core.current_role() as role_name,
    core.current_brand_id() as brand_id,
    core.current_store_id() as store_id
),
counts as (
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
        select count(*) from hr.payroll_records where status in ('pending', 'in_review')
      )
      when role_ctx.role_name = 'brandManager' then (
        select count(*) from hr.payroll_records where status in ('pending', 'in_review') and brand_id = role_ctx.brand_id
      )
      else (
        select count(*) from hr.payroll_records where status in ('pending', 'in_review') and store_id = role_ctx.store_id
      )
    end as payroll_pending_count,
    case
      when role_ctx.role_name = 'superAdmin' then (
        select count(*) from ops.quality_checks where status in ('pending', 'issue')
      )
      when role_ctx.role_name = 'brandManager' then (
        select count(*)
        from ops.quality_checks qc
        join ops.stores s on s.id = qc.store_id
        where qc.status in ('pending', 'issue')
          and s.brand_id = role_ctx.brand_id
      )
      else (
        select count(*) from ops.quality_checks where status in ('pending', 'issue') and store_id = role_ctx.store_id
      )
    end as quality_attention_count,
    case
      when role_ctx.role_name = 'superAdmin' then (
        select count(*) from accounting.expenses where status = 'pending'
      )
      when role_ctx.role_name = 'brandManager' then (
        select count(*)
        from accounting.expenses e
        join ops.stores s on s.id = e.store_id
        where e.status = 'pending'
          and s.brand_id = role_ctx.brand_id
      )
      else (
        select count(*) from accounting.expenses where status = 'pending' and store_id = role_ctx.store_id
      )
    end as expense_pending_count,
    case
      when role_ctx.role_name = 'superAdmin' then (
        select count(*) from accounting.purchase_requests where status = 'pending_approval'
      )
      when role_ctx.role_name = 'brandManager' then (
        select count(*)
        from accounting.purchase_requests pr
        where pr.status = 'pending_approval'
          and pr.brand_id = role_ctx.brand_id
      )
      else (
        select count(*) from accounting.purchase_requests where status = 'pending_approval' and store_id = role_ctx.store_id
      )
    end as purchase_pending_count,
    (
      select count(*)
      from documents.documents d
      where d.status = 'active'
    ) as active_document_count
  from role_ctx
)
select
  counts.brand_count,
  counts.store_count,
  counts.employee_count,
  counts.payroll_pending_count,
  counts.quality_attention_count,
  counts.expense_pending_count,
  counts.purchase_pending_count,
  counts.expense_pending_count + counts.purchase_pending_count as accounting_pending_count,
  counts.active_document_count,
  counts.payroll_pending_count
    + counts.quality_attention_count
    + counts.expense_pending_count
    + counts.purchase_pending_count as pending_items
from counts;
alter view dashboard.dashboard_summary_view set (security_invoker = true);
grant select on dashboard.dashboard_summary_view to authenticated;
