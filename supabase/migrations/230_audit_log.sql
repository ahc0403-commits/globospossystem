create table if not exists system.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_log_actor on system.audit_log(actor_id);
create index if not exists idx_audit_log_entity on system.audit_log(entity_type, entity_id);
create index if not exists idx_audit_log_created on system.audit_log(created_at desc);
alter table system.audit_log enable row level security;
drop policy if exists audit_log_select on system.audit_log;
create policy audit_log_select
on system.audit_log
for select
using (core.current_role() in ('superAdmin', 'brandManager'));
