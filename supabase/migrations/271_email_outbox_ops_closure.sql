-- Email outbox operational closure:
-- 1. Add bounded runtime summary + retry RPCs for the first-wave outbox.
-- 2. Wire scheduled invocation of the existing process-email-outbox edge function.
-- 3. Preserve first-wave scope: account_created, document_released only.

create extension if not exists pg_net;
create extension if not exists pg_cron;
create schema if not exists private;
create table if not exists private.runtime_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
create or replace function system.invoke_process_email_outbox(
  p_limit integer default 20
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
begin
  select value
  into v_dispatch_url
  from private.runtime_config
  where key = 'email_dispatch_function_url';

  if coalesce(trim(v_dispatch_url), '') = '' then
    raise exception 'private.runtime_config email_dispatch_function_url is not configured';
  end if;

  select value
  into v_dispatch_token
  from private.runtime_config
  where key = 'email_dispatch_token';

  if coalesce(trim(v_dispatch_token), '') = '' then
    raise exception 'private.runtime_config email_dispatch_token is not configured';
  end if;

  select net.http_post(
    url := trim(v_dispatch_url),
    body := '{}'::jsonb,
    params := jsonb_build_object(
      'limit',
      greatest(1, least(coalesce(p_limit, 20), 100))
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
create or replace function system.retry_email_outbox(
  p_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_row system.email_outbox%rowtype;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  select *
  into v_row
  from system.email_outbox
  where id = p_id
  for update;

  if not found then
    raise exception 'Email outbox row % not found', p_id;
  end if;

  if v_row.status not in ('failed', 'dead') then
    raise exception 'Only failed or dead rows can be retried';
  end if;

  update system.email_outbox
  set
    status = 'pending',
    next_attempt_at = now(),
    locked_at = null,
    updated_at = now()
  where id = p_id;

  perform system.write_audit_log(
    'email_outbox_retry_requested',
    'email_outbox',
    p_id,
    jsonb_build_object(
      'source_audit_log_id', v_row.source_audit_log_id,
      'event_action', v_row.event_action,
      'template_key', v_row.template_key,
      'recipient_email', v_row.recipient_email,
      'recipient_name', v_row.recipient_name,
      'previous_status', v_row.status,
      'attempt_count', v_row.attempt_count,
      'max_attempts', v_row.max_attempts
    )
  );
end;
$$;
create or replace function system.get_email_dispatch_runtime_summary()
returns table (
  schedule_active boolean,
  schedule_expression text,
  status_bucket text,
  status_label text,
  pending_count integer,
  processing_count integer,
  failed_count integer,
  dead_count integer,
  sent_last_24h integer,
  latest_created_at timestamptz,
  latest_sent_at timestamptz,
  latest_failure_at timestamptz
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
        where jobname = 'process-email-outbox-dispatch'
          and active = true
      ) as schedule_active,
      (
        select schedule
        from cron.job
        where jobname = 'process-email-outbox-dispatch'
          and active = true
        order by jobid desc
        limit 1
      ) as schedule_expression
  ),
  outbox_counts as (
    select
      count(*) filter (where status = 'pending')::int as pending_count,
      count(*) filter (where status = 'processing')::int as processing_count,
      count(*) filter (where status = 'failed')::int as failed_count,
      count(*) filter (where status = 'dead')::int as dead_count,
      count(*) filter (
        where status = 'sent'
          and sent_at >= now() - interval '24 hours'
      )::int as sent_last_24h,
      max(created_at) as latest_created_at,
      max(sent_at) as latest_sent_at,
      max(
        case
          when status in ('failed', 'dead') then updated_at
          else null
        end
      ) as latest_failure_at
    from system.email_outbox
  )
  select
    schedule_state.schedule_active,
    coalesce(schedule_state.schedule_expression, 'Not scheduled')::text,
    case
      when not schedule_state.schedule_active then 'action_required'
      when outbox_counts.dead_count > 0 then 'failed'
      when outbox_counts.failed_count > 0
        or outbox_counts.processing_count > 0
        or outbox_counts.pending_count > 0 then 'degraded'
      else 'healthy'
    end::text as status_bucket,
    case
      when not schedule_state.schedule_active then 'Action Required'
      when outbox_counts.dead_count > 0 then 'Failed'
      when outbox_counts.failed_count > 0
        or outbox_counts.processing_count > 0
        or outbox_counts.pending_count > 0 then 'Degraded'
      else 'Healthy'
    end::text as status_label,
    outbox_counts.pending_count,
    outbox_counts.processing_count,
    outbox_counts.failed_count,
    outbox_counts.dead_count,
    outbox_counts.sent_last_24h,
    outbox_counts.latest_created_at,
    outbox_counts.latest_sent_at,
    outbox_counts.latest_failure_at
  from schedule_state
  cross join outbox_counts;
end;
$$;
create or replace function system.mark_email_outbox_sent(
  p_id uuid,
  p_provider_message_id text default null,
  p_provider_response jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  update system.email_outbox
  set
    status = 'sent',
    last_error = null,
    provider = 'resend',
    provider_message_id = p_provider_message_id,
    provider_response = coalesce(p_provider_response, '{}'::jsonb),
    next_attempt_at = now(),
    sent_at = now(),
    locked_at = null,
    updated_at = now()
  where id = p_id;
end;
$$;
do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
    from cron.job
    where jobname = 'process-email-outbox-dispatch'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'process-email-outbox-dispatch',
    '*/5 * * * *',
    $cron$
      select system.invoke_process_email_outbox(20);
    $cron$
  );
end;
$$;
grant execute on function system.invoke_process_email_outbox(integer) to service_role;
grant execute on function system.retry_email_outbox(uuid) to authenticated;
grant execute on function system.get_email_dispatch_runtime_summary() to authenticated;
