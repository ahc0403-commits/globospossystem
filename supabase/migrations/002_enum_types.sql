do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'core' and t.typname = 'account_status'
  ) then
    create type core.account_status as enum ('active', 'inactive', 'pending', 'blocked');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'core' and t.typname = 'permission_domain'
  ) then
    create type core.permission_domain as enum ('hr', 'operations', 'accounting', 'documents', 'system');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'core' and t.typname = 'permission_action'
  ) then
    create type core.permission_action as enum ('view', 'create', 'edit', 'approve', 'confirm', 'reject', 'release', 'manage');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'core' and t.typname = 'scope_level'
  ) then
    create type core.scope_level as enum ('self', 'store', 'brand', 'company', 'global');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'hr' and t.typname = 'payroll_status'
  ) then
    create type hr.payroll_status as enum ('draft', 'pending', 'in_review', 'confirmed', 'rejected', 'returned');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'ops' and t.typname = 'quality_status'
  ) then
    create type ops.quality_status as enum ('pending', 'in_progress', 'completed', 'issue', 'resolved');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'accounting' and t.typname = 'request_status'
  ) then
    create type accounting.request_status as enum ('draft', 'pending_approval', 'approved', 'rejected', 'returned');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'accounting' and t.typname = 'expense_status'
  ) then
    create type accounting.expense_status as enum ('draft', 'pending', 'approved', 'rejected', 'returned');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'accounting' and t.typname = 'payable_status'
  ) then
    create type accounting.payable_status as enum ('upcoming', 'due', 'paid', 'overdue');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'documents' and t.typname = 'doc_status'
  ) then
    create type documents.doc_status as enum ('draft', 'active', 'archived', 'superseded');
  end if;
end $$;
