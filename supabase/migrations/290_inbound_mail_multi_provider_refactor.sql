-- Multi-provider inbound mail connector refactor (Gmail + Zoho).
--
-- Scope:
-- 1. Keep bounded intake contract and add provider-safe duplicate boundary.
-- 2. Promote inbound ingestion runtime to provider-aware invoke/summary contracts.
-- 3. Keep existing operational dispatch pattern (private.runtime_config + pg_net + pg_cron).

-- ── Intake duplicate boundary: provider + mailbox + external ref ────────────

alter table system.email_inbound_intake
  drop constraint if exists email_inbound_intake_message_ref_unique;
alter table system.email_inbound_intake
  add constraint email_inbound_intake_message_ref_unique
  unique (source_provider, source_mailbox, external_message_ref);
alter table system.email_inbound_intake
  drop constraint if exists email_inbound_intake_source_provider_check;
alter table system.email_inbound_intake
  add constraint email_inbound_intake_source_provider_check
  check (source_provider in ('gmail', 'zoho', 'unknown'));
create or replace function system.record_email_inbound_intake(
  p_source_provider text,
  p_source_mailbox text,
  p_external_message_ref text,
  p_received_at timestamptz,
  p_sender_email text,
  p_subject text,
  p_attachment_refs jsonb default '[]'::jsonb,
  p_attachment_count integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_source_provider text := lower(trim(coalesce(p_source_provider, 'gmail')));
  v_source_mailbox text := trim(coalesce(p_source_mailbox, ''));
  v_external_message_ref text := trim(coalesce(p_external_message_ref, ''));
  v_sender_email text := lower(trim(coalesce(p_sender_email, '')));
  v_subject text := nullif(trim(coalesce(p_subject, '')), '');
  v_attachment_refs jsonb := coalesce(p_attachment_refs, '[]'::jsonb);
  v_attachment_count integer;
  v_row_id uuid;
begin
  if v_source_provider = '' then
    v_source_provider := 'gmail';
  end if;

  if v_source_provider not in ('gmail', 'zoho', 'unknown') then
    raise exception 'Unsupported source_provider %', v_source_provider;
  end if;

  if v_source_mailbox = '' then
    raise exception 'source_mailbox is required';
  end if;

  if v_external_message_ref = '' then
    raise exception 'external_message_ref is required';
  end if;

  if v_sender_email = '' then
    raise exception 'sender_email is required';
  end if;

  if jsonb_typeof(v_attachment_refs) <> 'array' then
    raise exception 'attachment_refs must be a JSON array';
  end if;

  v_attachment_count := coalesce(
    p_attachment_count,
    jsonb_array_length(v_attachment_refs),
    0
  );

  if v_attachment_count < 0 then
    raise exception 'attachment_count must be >= 0';
  end if;

  insert into system.email_inbound_intake (
    source_provider,
    source_mailbox,
    external_message_ref,
    received_at,
    sender_email,
    subject,
    attachment_count,
    attachment_refs
  )
  values (
    v_source_provider,
    v_source_mailbox,
    v_external_message_ref,
    coalesce(p_received_at, now()),
    v_sender_email,
    v_subject,
    v_attachment_count,
    v_attachment_refs
  )
  on conflict (source_provider, source_mailbox, external_message_ref)
  do update set
    received_at = excluded.received_at,
    sender_email = excluded.sender_email,
    subject = excluded.subject,
    attachment_count = excluded.attachment_count,
    attachment_refs = excluded.attachment_refs,
    updated_at = now()
  returning id into v_row_id;

  return v_row_id;
end;
$$;
-- ── Provider-aware ingestion run diagnostics ────────────────────────────────

alter table system.email_inbound_ingestion_runs
  drop constraint if exists email_inbound_ingestion_runs_source_provider_check;
alter table system.email_inbound_ingestion_runs
  add constraint email_inbound_ingestion_runs_source_provider_check
  check (source_provider in ('gmail', 'zoho', 'unknown'));
create index if not exists idx_email_inbound_ingestion_runs_provider_finished
  on system.email_inbound_ingestion_runs(source_provider, finished_at desc, created_at desc);
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
  if v_source_provider not in ('gmail', 'zoho', 'unknown') then
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
-- ── Provider-aware dispatch invoke contract ─────────────────────────────────

create or replace function system.invoke_ingest_inbound_mail(
  p_source_provider text default 'gmail',
  p_limit integer default 25,
  p_trigger_mode text default 'manual'
)
returns bigint
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system, private, net, cron
as $$
declare
  v_source_provider text := lower(trim(coalesce(p_source_provider, 'gmail')));
  v_trigger_mode text := lower(trim(coalesce(p_trigger_mode, 'manual')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  v_dispatch_url text;
  v_dispatch_token text;
  v_request_id bigint;
begin
  if session_user <> 'postgres' and core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if v_source_provider not in ('gmail', 'zoho') then
    raise exception 'source_provider must be gmail or zoho';
  end if;

  if v_trigger_mode not in ('manual', 'scheduled') then
    raise exception 'trigger_mode must be manual or scheduled';
  end if;

  if v_source_provider = 'gmail' then
    select value into v_dispatch_url
    from private.runtime_config
    where key = 'gmail_intake_function_url';

    select value into v_dispatch_token
    from private.runtime_config
    where key = 'gmail_intake_dispatch_token';
  elsif v_source_provider = 'zoho' then
    select value into v_dispatch_url
    from private.runtime_config
    where key = 'zoho_intake_function_url';

    select value into v_dispatch_token
    from private.runtime_config
    where key = 'zoho_intake_dispatch_token';
  end if;

  if coalesce(trim(v_dispatch_url), '') = '' then
    select value into v_dispatch_url
    from private.runtime_config
    where key = 'inbound_mail_function_url';
  end if;

  if coalesce(trim(v_dispatch_token), '') = '' then
    select value into v_dispatch_token
    from private.runtime_config
    where key = 'inbound_mail_dispatch_token';
  end if;

  if coalesce(trim(v_dispatch_url), '') = '' then
    raise exception 'No inbound mail function URL is configured for provider %', v_source_provider;
  end if;

  if coalesce(trim(v_dispatch_token), '') = '' then
    raise exception 'No inbound mail dispatch token is configured for provider %', v_source_provider;
  end if;

  select net.http_post(
    url := trim(v_dispatch_url),
    body := '{}'::jsonb,
    params := jsonb_build_object(
      'provider',
      v_source_provider,
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
grant execute on function system.invoke_ingest_inbound_mail(text, integer, text)
  to authenticated;
create or replace function system.invoke_ingest_gmail_inbound_intake(
  p_limit integer default 25,
  p_trigger_mode text default 'manual'
)
returns bigint
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  return system.invoke_ingest_inbound_mail('gmail', p_limit, p_trigger_mode);
end;
$$;
create or replace function system.invoke_ingest_zoho_inbound_intake(
  p_limit integer default 25,
  p_trigger_mode text default 'manual'
)
returns bigint
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  return system.invoke_ingest_inbound_mail('zoho', p_limit, p_trigger_mode);
end;
$$;
grant execute on function system.invoke_ingest_gmail_inbound_intake(integer, text)
  to authenticated;
grant execute on function system.invoke_ingest_zoho_inbound_intake(integer, text)
  to authenticated;
-- ── Provider-aware runtime summary ──────────────────────────────────────────

create or replace function system.get_email_inbound_ingestion_runtime_summary(
  p_source_provider text default 'gmail'
)
returns table (
  source_provider text,
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
declare
  v_source_provider text := lower(trim(coalesce(p_source_provider, 'gmail')));
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if v_source_provider not in ('gmail', 'zoho') then
    raise exception 'source_provider must be gmail or zoho';
  end if;

  return query
  with schedule_state as (
    select
      exists(
        select 1
        from cron.job
        where jobname = 'ingest-inbound-mail-dispatch'
          and active = true
      ) as schedule_active,
      (
        select schedule
        from cron.job
        where jobname = 'ingest-inbound-mail-dispatch'
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
    where r.source_provider = v_source_provider
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
    where r.source_provider = v_source_provider
      and r.finished_at >= now() - interval '24 hours'
  )
  select
    v_source_provider::text,
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
grant execute on function system.get_email_inbound_ingestion_runtime_summary(text)
  to authenticated;
-- Drop the no-arg overload from migration 289 because its return type changed
-- (added source_provider column). PostgreSQL does not allow return type changes
-- via CREATE OR REPLACE.
drop function if exists system.get_email_inbound_ingestion_runtime_summary();
create function system.get_email_inbound_ingestion_runtime_summary()
returns table (
  source_provider text,
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
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  return query
  select *
  from system.get_email_inbound_ingestion_runtime_summary('gmail');
end;
$$;
grant execute on function system.get_email_inbound_ingestion_runtime_summary()
  to authenticated;
-- ── Multi-provider schedule dispatch ────────────────────────────────────────

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
    where jobname in (
      'ingest-gmail-inbound-intake-dispatch',
      'ingest-inbound-mail-dispatch'
    )
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'ingest-inbound-mail-dispatch',
    '*/10 * * * *',
    $cron$
      select system.invoke_ingest_inbound_mail('gmail', 25, 'scheduled');
      select system.invoke_ingest_inbound_mail('zoho', 25, 'scheduled');
    $cron$
  );
end;
$$;
