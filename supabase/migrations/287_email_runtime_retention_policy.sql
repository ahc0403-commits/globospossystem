-- Email runtime retention policy:
-- 1. Keep the Office system bounded to operational outbound email data.
-- 2. Prune resolved outbox rows and enqueue diagnostics after 90 days.
-- 3. Preserve unresolved queue rows so current delivery behavior stays intact.

create or replace function system.apply_email_runtime_retention(
  p_outbox_retention interval default interval '90 days',
  p_diagnostic_retention interval default interval '90 days'
)
returns table (
  pruned_outbox_count integer,
  pruned_diagnostic_count integer,
  outbox_cutoff timestamptz,
  diagnostic_cutoff timestamptz
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_outbox_retention interval := coalesce(p_outbox_retention, interval '90 days');
  v_diagnostic_retention interval := coalesce(p_diagnostic_retention, interval '90 days');
  v_outbox_cutoff timestamptz;
  v_diagnostic_cutoff timestamptz;
  v_pruned_outbox integer := 0;
  v_pruned_diagnostics integer := 0;
begin
  if v_outbox_retention <= interval '0 seconds' then
    raise exception 'Outbox retention must be positive';
  end if;

  if v_diagnostic_retention <= interval '0 seconds' then
    raise exception 'Diagnostic retention must be positive';
  end if;

  v_outbox_cutoff := now() - v_outbox_retention;
  v_diagnostic_cutoff := now() - v_diagnostic_retention;

  delete from system.email_outbox eo
  where eo.status in ('sent', 'failed', 'dead')
    and coalesce(eo.sent_at, eo.updated_at, eo.created_at) < v_outbox_cutoff;

  get diagnostics v_pruned_outbox = row_count;

  delete from system.email_enqueue_diagnostics d
  where d.created_at < v_diagnostic_cutoff;

  get diagnostics v_pruned_diagnostics = row_count;

  return query
  select
    v_pruned_outbox,
    v_pruned_diagnostics,
    v_outbox_cutoff,
    v_diagnostic_cutoff;
end;
$$;
do $$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is null then
    return;
  end if;

  for v_job_id in
    select jobid
    from cron.job
    where jobname = 'email-runtime-retention-cleanup'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'email-runtime-retention-cleanup',
    '30 3 * * *',
    $cron$
      select *
      from system.apply_email_runtime_retention();
    $cron$
  );
end;
$$;
grant execute on function system.apply_email_runtime_retention(interval, interval) to service_role;
