create or replace function system.update_account_status(account_id uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  update core.accounts
  set status = case when active then 'active' else 'inactive' end::core.account_status
  where id = account_id;
end; $$;
create or replace function system.save_permissions(
  account_id uuid,
  role text,
  scope_brand_id uuid,
  scope_store_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  update core.accounts
  set role = role, scope_brand_id = scope_brand_id, scope_store_id = scope_store_id
  where id = account_id;
end; $$;
create or replace function hr.confirm_payroll(record_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from hr.payroll_records pr
      join ops.stores s on s.id = pr.store_id
      where pr.id = record_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update hr.payroll_records
  set status = 'confirmed'
  where id = record_id;
end; $$;
create or replace function hr.reject_payroll(record_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager', 'storeManager') then
    raise exception 'Insufficient permissions: storeManager+ required';
  end if;

  if core.current_role() = 'storeManager' then
    if not exists (
      select 1
      from hr.payroll_records pr
      where pr.id = record_id and pr.store_id = core.current_store_id()
    ) then
      raise exception 'Record is outside your store scope';
    end if;
  elsif core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from hr.payroll_records pr
      join ops.stores s on s.id = pr.store_id
      where pr.id = record_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update hr.payroll_records
  set status = 'rejected'
  where id = record_id;
end; $$;
create or replace function hr.return_payroll(record_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager', 'storeManager') then
    raise exception 'Insufficient permissions: storeManager+ required';
  end if;

  if core.current_role() = 'storeManager' then
    if not exists (
      select 1
      from hr.payroll_records pr
      where pr.id = record_id and pr.store_id = core.current_store_id()
    ) then
      raise exception 'Record is outside your store scope';
    end if;
  elsif core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from hr.payroll_records pr
      join ops.stores s on s.id = pr.store_id
      where pr.id = record_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update hr.payroll_records
  set status = 'returned'
  where id = record_id;
end; $$;
create or replace function ops.flag_quality_issue(check_id uuid, note text)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager', 'storeManager') then
    raise exception 'Insufficient permissions: storeManager+ required';
  end if;

  if core.current_role() = 'storeManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      where qc.id = check_id and qc.store_id = core.current_store_id()
    ) then
      raise exception 'Record is outside your store scope';
    end if;
  elsif core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      join ops.stores s on s.id = qc.store_id
      where qc.id = check_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update ops.quality_checks
  set status = 'issue', issue_note = note
  where id = check_id;
end; $$;
create or replace function ops.complete_quality_check(check_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager', 'storeManager') then
    raise exception 'Insufficient permissions: storeManager+ required';
  end if;

  if core.current_role() = 'storeManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      where qc.id = check_id and qc.store_id = core.current_store_id()
    ) then
      raise exception 'Record is outside your store scope';
    end if;
  elsif core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      join ops.stores s on s.id = qc.store_id
      where qc.id = check_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update ops.quality_checks
  set status = 'completed'
  where id = check_id;
end; $$;
create or replace function accounting.approve_expense(expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.expenses e
      join ops.stores s on s.id = e.store_id
      where e.id = expense_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.expenses
  set status = 'approved'
  where id = expense_id;
end; $$;
create or replace function accounting.return_expense(expense_id uuid, note text)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.expenses e
      join ops.stores s on s.id = e.store_id
      where e.id = expense_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.expenses
  set status = 'returned', return_note = note
  where id = expense_id;
end; $$;
create or replace function accounting.approve_purchase(purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.purchase_requests pr
      where pr.id = purchase_id and pr.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.purchase_requests
  set status = 'approved'
  where id = purchase_id;
end; $$;
create or replace function accounting.reject_purchase(purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.purchase_requests pr
      where pr.id = purchase_id and pr.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.purchase_requests
  set status = 'rejected'
  where id = purchase_id;
end; $$;
create or replace function documents.release_document(document_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from documents.documents d
      where d.id = document_id and d.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update documents.documents
  set status = 'active'
  where id = document_id;
end; $$;
