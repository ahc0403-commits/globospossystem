-- Follow-up for bounded runtime validation:
-- allow postgres-session validation while preserving superAdmin access from app runtime.

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
  if session_user <> 'postgres' and core.current_role() <> 'superAdmin' then
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
