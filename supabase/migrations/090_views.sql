create or replace function dashboard.get_summary()
returns table (
  brand_count bigint,
  store_count bigint,
  employee_count bigint,
  pending_items bigint
)
language plpgsql
stable
security invoker
set search_path = public, core, ops, hr, accounting, documents, dashboard
as $$
declare
  role_name text;
begin
  role_name := core.current_role();

  if role_name = 'superAdmin' then
    brand_count := (select count(*) from ops.brands);
    store_count := (select count(*) from ops.stores);
    employee_count := (select count(*) from hr.employees);
    pending_items := (
      (select count(*) from hr.payroll_records where status in ('pending', 'in_review')) +
      (select count(*) from ops.quality_checks where status in ('pending', 'issue')) +
      (select count(*) from accounting.expenses where status = 'pending') +
      (select count(*) from accounting.purchase_requests where status = 'pending_approval')
    );
    return;
  end if;

  if role_name = 'brandManager' then
    brand_count := (select count(*) from ops.brands where id = core.current_brand_id());
    store_count := (select count(*) from ops.stores where brand_id = core.current_brand_id());
    employee_count := (select count(*) from hr.employees where brand_id = core.current_brand_id());
    pending_items := (
      (select count(*)
       from hr.payroll_records pr
       where pr.status in ('pending', 'in_review')
         and pr.brand_id = core.current_brand_id()) +
      (select count(*)
       from ops.quality_checks qc
       join ops.stores s on s.id = qc.store_id
       where qc.status in ('pending', 'issue')
         and s.brand_id = core.current_brand_id()) +
      (select count(*)
       from accounting.expenses e
       join ops.stores s on s.id = e.store_id
       where e.status = 'pending'
         and s.brand_id = core.current_brand_id()) +
      (select count(*)
       from accounting.purchase_requests pr
       where pr.status = 'pending_approval'
         and pr.brand_id = core.current_brand_id())
    );
    return;
  end if;

  brand_count := (select count(*) from ops.brands where id = core.current_brand_id());
  store_count := (select count(*) from ops.stores where id = core.current_store_id());
  employee_count := (select count(*) from hr.employees where store_id = core.current_store_id());
  pending_items := (
    (select count(*) from hr.payroll_records where status in ('pending', 'in_review') and store_id = core.current_store_id()) +
    (select count(*) from ops.quality_checks where status in ('pending', 'issue') and store_id = core.current_store_id()) +
    (select count(*) from accounting.expenses where status = 'pending' and store_id = core.current_store_id()) +
    (select count(*) from accounting.purchase_requests where status = 'pending_approval' and store_id = core.current_store_id())
  );
end;
$$;
