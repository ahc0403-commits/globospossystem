alter table core.accounts enable row level security;
alter table core.account_permissions enable row level security;
alter table ops.brands enable row level security;
alter table ops.stores enable row level security;
alter table hr.employees enable row level security;
alter table hr.payroll_records enable row level security;
alter table ops.quality_checks enable row level security;
alter table accounting.purchase_requests enable row level security;
alter table accounting.expenses enable row level security;
alter table accounting.payables enable row level security;
alter table accounting.accounting_entries enable row level security;
alter table documents.documents enable row level security;
alter table documents.document_versions enable row level security;
drop policy if exists accounts_select on core.accounts;
create policy accounts_select on core.accounts
  for select
  using (id = auth.uid() or core.current_role() = 'superAdmin');
drop policy if exists accounts_update_admin on core.accounts;
create policy accounts_update_admin on core.accounts
  for update
  using (core.current_role() = 'superAdmin')
  with check (core.current_role() = 'superAdmin');
drop policy if exists account_permissions_select on core.account_permissions;
create policy account_permissions_select on core.account_permissions
  for select
  using (account_id = auth.uid() or core.current_role() = 'superAdmin');
drop policy if exists account_permissions_manage on core.account_permissions;
create policy account_permissions_manage on core.account_permissions
  for all
  using (core.current_role() = 'superAdmin')
  with check (core.current_role() = 'superAdmin');
drop policy if exists brands_select_scoped on ops.brands;
create policy brands_select_scoped on ops.brands
  for select
  using (core.current_role() = 'superAdmin' or id = core.current_brand_id());
drop policy if exists brands_manage_admin on ops.brands;
create policy brands_manage_admin on ops.brands
  for all
  using (core.current_role() = 'superAdmin')
  with check (core.current_role() = 'superAdmin');
drop policy if exists stores_select_scoped on ops.stores;
create policy stores_select_scoped on ops.stores
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or id = core.current_store_id()
  );
drop policy if exists stores_manage_admin on ops.stores;
create policy stores_manage_admin on ops.stores
  for all
  using (core.current_role() = 'superAdmin')
  with check (core.current_role() = 'superAdmin');
drop policy if exists employees_select_scoped on hr.employees;
create policy employees_select_scoped on hr.employees
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
drop policy if exists employees_manage_scoped on hr.employees;
create policy employees_manage_scoped on hr.employees
  for all
  using (core.current_role() in ('superAdmin', 'brandManager', 'storeManager'))
  with check (core.current_role() in ('superAdmin', 'brandManager', 'storeManager'));
drop policy if exists payroll_select_scoped on hr.payroll_records;
create policy payroll_select_scoped on hr.payroll_records
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
drop policy if exists quality_select_scoped on ops.quality_checks;
create policy quality_select_scoped on ops.quality_checks
  for select
  using (
    core.current_role() = 'superAdmin'
    or store_id = core.current_store_id()
    or exists (
      select 1
      from ops.stores s
      where s.id = ops.quality_checks.store_id
        and s.brand_id = core.current_brand_id()
    )
  );
drop policy if exists purchases_select_scoped on accounting.purchase_requests;
create policy purchases_select_scoped on accounting.purchase_requests
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
drop policy if exists expenses_select_scoped on accounting.expenses;
create policy expenses_select_scoped on accounting.expenses
  for select
  using (
    core.current_role() = 'superAdmin'
    or store_id = core.current_store_id()
    or exists (
      select 1
      from ops.stores s
      where s.id = accounting.expenses.store_id
        and s.brand_id = core.current_brand_id()
    )
  );
drop policy if exists payables_select_scoped on accounting.payables;
create policy payables_select_scoped on accounting.payables
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
drop policy if exists accounting_entries_select on accounting.accounting_entries;
create policy accounting_entries_select on accounting.accounting_entries
  for select
  using (core.current_role() in ('superAdmin', 'brandManager', 'storeManager'));
drop policy if exists documents_select_scoped on documents.documents;
create policy documents_select_scoped on documents.documents
  for select
  using (
    visibility = 'all'
    or core.current_role() = 'superAdmin'
    or (visibility = 'brand' and brand_id = core.current_brand_id())
    or (visibility = 'admin' and core.current_role() in ('superAdmin', 'brandManager'))
    or (visibility = 'store' and core.current_store_id() is not null)
  );
drop policy if exists document_versions_select on documents.document_versions;
create policy document_versions_select on documents.document_versions
  for select
  using (true);
