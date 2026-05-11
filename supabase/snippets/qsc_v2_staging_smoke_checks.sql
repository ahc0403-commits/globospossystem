-- QSC v2 staging smoke checks
-- CLI-safe version for:
-- supabase db query --project-ref <ref> -f supabase/snippets/qsc_v2_staging_smoke_checks.sql -o json

create or replace function pg_temp.safe_view_sample(
  p_view_name text,
  p_limit integer default 3
) returns jsonb
language plpgsql
as $$
declare
  v_exists regclass;
  v_payload jsonb;
begin
  v_exists := to_regclass(p_view_name);
  if v_exists is null then
    return jsonb_build_object('exists', false, 'rows', jsonb_build_array());
  end if;

  execute format(
    'select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from %s limit %s) t',
    p_view_name,
    greatest(p_limit, 0)
  )
  into v_payload;

  return jsonb_build_object('exists', true, 'rows', coalesce(v_payload, '[]'::jsonb));
end;
$$;

select
  'restaurants_coupling_columns' as section,
  jsonb_agg(
    jsonb_build_object(
      'column_name', column_name,
      'data_type', data_type,
      'is_nullable', is_nullable
    )
    order by column_name
  ) as payload
from information_schema.columns
where table_schema = 'public'
  and table_name = 'restaurants'
  and column_name in ('id', 'name', 'address', 'is_active');

select
  'qc_checks_uniqueness_constraints' as section,
  jsonb_agg(
    jsonb_build_object(
      'constraint_name', conname,
      'definition', pg_get_constraintdef(oid)
    )
    order by conname
  ) as payload
from pg_constraint
where conrelid = 'public.qc_checks'::regclass
  and contype = 'u';

select
  'qc_templates_qsc_columns' as section,
  jsonb_agg(
    jsonb_build_object(
      'column_name', column_name,
      'data_type', data_type
    )
    order by column_name
  ) as payload
from information_schema.columns
where table_schema = 'public'
  and table_name = 'qc_templates'
  and column_name in (
    'qsc_domain',
    'requires_photo',
    'required_photo_count',
    'weight',
    'sort_group',
    'is_sv_required'
  );

select
  'qc_checks_qsc_columns' as section,
  jsonb_agg(
    jsonb_build_object(
      'column_name', column_name,
      'data_type', data_type
    )
    order by column_name
  ) as payload
from information_schema.columns
where table_schema = 'public'
  and table_name = 'qc_checks'
  and column_name in (
    'scheduled_at',
    'due_at',
    'submitted_at',
    'submission_status',
    'photo_required_count',
    'photo_uploaded_count',
    'score',
    'grade',
    'sv_review_status',
    'sv_reviewed_by',
    'sv_reviewed_at',
    'sv_score',
    'sv_note',
    'visit_session_id'
  );

select
  'qsc_object_presence' as section,
  jsonb_build_object(
    'qc_check_photos_table', to_regclass('public.qc_check_photos'),
    'v_quality_monitoring', to_regclass('public.v_quality_monitoring'),
    'v_qsc_dashboard_summary', to_regclass('public.v_qsc_dashboard_summary'),
    'v_qsc_store_status', to_regclass('public.v_qsc_store_status'),
    'v_qsc_item_status', to_regclass('public.v_qsc_item_status'),
    'v_office_qsc_dashboard', to_regclass('public.v_office_qsc_dashboard'),
    'v_office_qsc_store_latest', to_regclass('public.v_office_qsc_store_latest'),
    'v_office_qsc_issue_queue', to_regclass('public.v_office_qsc_issue_queue')
  ) as payload;

select
  'v_quality_monitoring_legacy_front_columns' as section,
  jsonb_agg(
    jsonb_build_object(
      'column_name', column_name,
      'ordinal_position', ordinal_position
    )
    order by ordinal_position
  ) as payload
from information_schema.columns
where table_schema = 'public'
  and table_name = 'v_quality_monitoring'
  and ordinal_position <= 12;

select
  'v_quality_monitoring_qsc_columns' as section,
  jsonb_agg(
    jsonb_build_object(
      'column_name', column_name,
      'ordinal_position', ordinal_position
    )
    order by ordinal_position
  ) as payload
from information_schema.columns
where table_schema = 'public'
  and table_name = 'v_quality_monitoring'
  and column_name in (
    'qsc_domain',
    'requires_photo',
    'required_photo_count',
    'photo_uploaded_count',
    'photo_status',
    'submission_status',
    'submitted_at',
    'score',
    'grade',
    'sv_review_status',
    'sv_reviewed_by',
    'sv_reviewed_at',
    'sv_score',
    'improvement_required',
    'followup_status',
    'followup_id',
    'followup_assigned_to_name',
    'followup_resolved_at',
    'visit_session_id'
  );

select
  'qsc_rpc_presence' as section,
  jsonb_agg(
    jsonb_build_object(
      'proname', proname,
      'arg_types', oidvectortypes(proargtypes)
    )
    order by proname, oidvectortypes(proargtypes)
  ) as payload
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in (
    'upsert_qc_check',
    'upsert_qc_check_photo',
    'refresh_qc_check_photo_summary',
    'submit_qc_visit_review',
    'get_qc_checks',
    'get_qc_templates',
    'create_qc_template',
    'update_qc_template'
  );

select
  'v_office_qsc_dashboard_sample' as section,
  pg_temp.safe_view_sample('public.v_office_qsc_dashboard', 3) as payload;

select
  'v_office_qsc_store_latest_sample' as section,
  pg_temp.safe_view_sample('public.v_office_qsc_store_latest', 3) as payload;

select
  'v_office_qsc_issue_queue_sample' as section,
  pg_temp.safe_view_sample('public.v_office_qsc_issue_queue', 3) as payload;
