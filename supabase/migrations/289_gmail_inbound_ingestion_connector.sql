-- Gmail inbound ingestion connector (bounded intake path).
--
-- Scope:
-- 1. Add bounded ingestion run diagnostics for inbound intake.
-- 2. Add superAdmin runtime summary and manual dispatch RPCs.
-- 3. Wire scheduled dispatch to the Edge Function connector path.
--
-- Boundary:
-- - Gmail remains source of truth for raw email + original binaries.
-- - Office stores bounded intake metadata and attachment references only.

create extension if not exists pg_net;
create extension if not exists pg_cron;
create table if not exists system.email_inbound_ingestion_runs (
  id uuid primary key default gen_random_uuid(),
  source_provider text not null default 'gmail' check (
    source_provider in ('gmail', 'unknown')
  ),
  source_mailbox text not null,
  trigger_mode text not null check (trigger_mode in ('manual', 'scheduled')),
  run_status text not null check (run_status in ('ok', 'partial', 'failed', 'idle')),
  started_at timestamptz not null,
  finished_at timestamptz not null,
  messages_scanned integer not null default 0 check (messages_scanned >= 0),
  records_created integer not null default 0 check (records_created >= 0),
  duplicates_skipped integer not null default 0 check (duplicates_skipped >= 0),
  skipped_count integer not null default 0 check (skipped_count >= 0),
  failures_count integer not null default 0 check (failures_count >= 0),
  diagnostic_message text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_inbound_ingestion_runs_detail_object
    check (jsonb_typeof(detail) = 'object')
);
create index if not exists idx_email_inbound_ingestion_runs_created
  on system.email_inbound_ingestion_runs(created_at desc);
create index if not exists idx_email_inbound_ingestion_runs_status
  on system.email_inbound_ingestion_runs(run_status, created_at desc);
create or replace function system.touch_email_inbound_ingestion_runs_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists trg_touch_email_inbound_ingestion_runs_updated_at
  on system.email_inbound_ingestion_runs;
create trigger trg_touch_email_inbound_ingestion_runs_updated_at
before update on system.email_inbound_ingestion_runs
for each row
execute function system.touch_email_inbound_ingestion_runs_updated_at();
alter table system.email_inbound_ingestion_runs enable row level security;
drop policy if exists email_inbound_ingestion_runs_select_admin
  on system.email_inbound_ingestion_runs;
create policy email_inbound_ingestion_runs_select_admin
on system.email_inbound_ingestion_runs
for select
to authenticated
using (core.current_role() = 'superAdmin');
grant usage on schema system to authenticated, service_role;
grant select on system.email_inbound_ingestion_runs to authenticated, service_role;
grant insert, update on system.email_inbound_ingestion_runs to service_role;
create or replace function system.record_email_inbound_ingestion_run(
  p_source_provider text default 'gmail',
  p_source_mailbox text default 'primary',
  p_trigger_mode text default 'manual',
  p_run_status text default 'idle',
  p_started_at timestamptz default now(),
  p_finished_at timestamptz default now(),
  p_messages_scanned integer default 0,
  p_records_created integer default 0,
  p_duplicates_skipped integer default 0,
  p_skipped_count integer default 0,
  p_failures_count integer default 0,
  p_diagnostic_message text default null,
  p_detail jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_source_provider text := lower(trim(coalesce(p_source_provider, 'gmail')));
  v_source_mailbox text := trim(coalesce(p_source_mailbox, 'primary'));
  v_trigger_mode text := lower(trim(coalesce(p_trigger_mode, 'manual')));
  v_run_status text := lower(trim(coalesce(p_run_status, 'idle')));
  v_detail jsonb := coalesce(p_detail, '{}'::jsonb);
  v_row_id uuid;
begin
  if v_source_provider not in ('gmail', 'unknown') then
    raise exception 'Unsupported source_provider %', v_source_provider;
  end if;

  if v_source_mailbox = '' then
    raise exception 'source_mailbox is required';
  end if;

  if v_trigger_mode not in ('manual', 'scheduled') then
    raise exception 'trigger_mode must be manual or scheduled';
  end if;

  if v_run_status not in ('ok', 'partial', 'failed', 'idle') then
    raise exception 'run_status must be one of: ok, partial, failed, idle';
  end if;

  if jsonb_typeof(v_detail) <> 'object' then
    raise exception 'detail must be a JSON object';
  end if;

  insert into system.email_inbound_ingestion_runs (
    source_provider,
    source_mailbox,
    trigger_mode,
    run_status,
    started_at,
    finished_at,
    messages_scanned,
    records_created,
    duplicates_skipped,
    skipped_count,
    failures_count,
    diagnostic_message,
    detail
  )
  values (
    v_source_provider,
    v_source_mailbox,
    v_trigger_mode,
    v_run_status,
    coalesce(p_started_at, now()),
    coalesce(p_finished_at, now()),
    greatest(0, coalesce(p_messages_scanned, 0)),
    greatest(0, coalesce(p_records_created, 0)),
    greatest(0, coalesce(p_duplicates_skipped, 0)),
    greatest(0, coalesce(p_skipped_count, 0)),
    greatest(0, coalesce(p_failures_count, 0)),
    nullif(trim(coalesce(p_diagnostic_message, '')), ''),
    v_detail
  )
  returning id into v_row_id;

  return v_row_id;
end;
$$;
grant execute on function system.record_email_inbound_ingestion_run(
  text,
  text,
  text,
  text,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  integer,
  integer,
  text,
  jsonb
) to service_role;
create or replace function system.invoke_ingest_gmail_inbound_intake(
  p_limit integer default 25,
  p_trigger_mode text default 'manual'
)
returns bigint
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system, private, net, cron
as $$
declare
  v_dispatch_url text;
  v_dispatch_token text;
  v_request_id bigint;
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  v_trigger_mode text := lower(trim(coalesce(p_trigger_mode, 'manual')));
begin
  if session_user <> 'postgres' and core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if v_trigger_mode not in ('manual', 'scheduled') then
    raise exception 'trigger_mode must be manual or scheduled';
  end if;

  select value
  into v_dispatch_url
  from private.runtime_config
  where key = 'gmail_intake_function_url';

  if coalesce(trim(v_dispatch_url), '') = '' then
    raise exception 'private.runtime_config gmail_intake_function_url is not configured';
  end if;

  select value
  into v_dispatch_token
  from private.runtime_config
  where key = 'gmail_intake_dispatch_token';

  if coalesce(trim(v_dispatch_token), '') = '' then
    raise exception 'private.runtime_config gmail_intake_dispatch_token is not configured';
  end if;

  select net.http_post(
    url := trim(v_dispatch_url),
    body := '{}'::jsonb,
    params := jsonb_build_object(
      'limit',
      v_limit,
      'trigger_mode',
      v_trigger_mode
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || trim(v_dispatch_token)
    )
  )
  into v_request_id;

  return v_request_id;
end;
$$;
grant execute on function system.invoke_ingest_gmail_inbound_intake(integer, text)
  to authenticated;
create or replace function system.get_email_inbound_ingestion_runtime_summary()
returns table (
  schedule_active boolean,
  schedule_expression text,
  status_bucket text,
  status_label text,
  last_run_at timestamptz,
  last_run_status text,
  last_records_created integer,
  last_duplicates_skipped integer,
  last_skipped_count integer,
  last_failures_count integer,
  last_diagnostic_message text,
  runs_last_24h integer,
  created_last_24h integer,
  duplicates_last_24h integer,
  failures_last_24h integer
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system, cron
as $$
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  return query
  with schedule_state as (
    select
      exists(
        select 1
        from cron.job
        where jobname = 'ingest-gmail-inbound-intake-dispatch'
          and active = true
      ) as schedule_active,
      (
        select schedule
        from cron.job
        where jobname = 'ingest-gmail-inbound-intake-dispatch'
          and active = true
        order by jobid desc
        limit 1
      ) as schedule_expression
  ),
  latest_run as (
    select
      r.finished_at,
      r.run_status,
      r.records_created,
      r.duplicates_skipped,
      r.skipped_count,
      r.failures_count,
      r.diagnostic_message
    from system.email_inbound_ingestion_runs r
    order by r.finished_at desc, r.created_at desc
    limit 1
  ),
  day_totals as (
    select
      count(*)::int as runs_last_24h,
      coalesce(sum(r.records_created), 0)::int as created_last_24h,
      coalesce(sum(r.duplicates_skipped), 0)::int as duplicates_last_24h,
      coalesce(sum(r.failures_count), 0)::int as failures_last_24h
    from system.email_inbound_ingestion_runs r
    where r.finished_at >= now() - interval '24 hours'
  )
  select
    schedule_state.schedule_active,
    coalesce(schedule_state.schedule_expression, 'Not scheduled')::text,
    case
      when not schedule_state.schedule_active then 'action_required'
      when latest_run.finished_at is null then 'degraded'
      when latest_run.run_status = 'failed' then 'failed'
      when latest_run.run_status = 'partial' then 'degraded'
      when latest_run.finished_at < now() - interval '6 hours' then 'degraded'
      else 'healthy'
    end::text as status_bucket,
    case
      when not schedule_state.schedule_active then 'Action Required'
      when latest_run.finished_at is null then 'Degraded'
      when latest_run.run_status = 'failed' then 'Failed'
      when latest_run.run_status = 'partial' then 'Degraded'
      when latest_run.finished_at < now() - interval '6 hours' then 'Degraded'
      else 'Healthy'
    end::text as status_label,
    latest_run.finished_at,
    latest_run.run_status,
    coalesce(latest_run.records_created, 0)::int,
    coalesce(latest_run.duplicates_skipped, 0)::int,
    coalesce(latest_run.skipped_count, 0)::int,
    coalesce(latest_run.failures_count, 0)::int,
    latest_run.diagnostic_message,
    day_totals.runs_last_24h,
    day_totals.created_last_24h,
    day_totals.duplicates_last_24h,
    day_totals.failures_last_24h
  from schedule_state
  cross join day_totals
  left join latest_run on true;
end;
$$;
grant execute on function system.get_email_inbound_ingestion_runtime_summary()
  to authenticated;
create or replace function system.apply_email_inbound_ingestion_retention(
  p_retention interval default interval '90 days'
)
returns table (
  pruned_count integer,
  cutoff timestamptz
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_retention interval := coalesce(p_retention, interval '90 days');
  v_cutoff timestamptz;
  v_pruned integer := 0;
begin
  if v_retention <= interval '0 seconds' then
    raise exception 'Retention must be positive';
  end if;

  v_cutoff := now() - v_retention;

  delete from system.email_inbound_ingestion_runs r
  where coalesce(r.finished_at, r.created_at) < v_cutoff;

  get diagnostics v_pruned = row_count;

  return query
  select v_pruned, v_cutoff;
end;
$$;
grant execute on function system.apply_email_inbound_ingestion_retention(interval)
  to service_role;
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
    where jobname = 'ingest-gmail-inbound-intake-dispatch'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'ingest-gmail-inbound-intake-dispatch',
    '*/10 * * * *',
    $cron$
      select system.invoke_ingest_gmail_inbound_intake(25, 'scheduled');
    $cron$
  );
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
    where jobname = 'email-inbound-ingestion-retention-cleanup'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'email-inbound-ingestion-retention-cleanup',
    '50 3 * * *',
    $cron$
      select *
      from system.apply_email_inbound_ingestion_retention();
    $cron$
  );
end;
$$;
