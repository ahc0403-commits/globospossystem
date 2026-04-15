create or replace view dashboard.admin_monitoring_summary_view as
with role_ctx as (
  select core.current_role() as role_name
),
managed_accounts as (
  select
    oup.auth_id,
    oup.account_level,
    oup.scope_type,
    oup.scope_ids,
    oup.is_active
  from public.office_user_profiles oup
  cross join role_ctx
  where role_ctx.role_name = 'superAdmin'
)
select
  count(*)::int as total_managed_accounts,
  count(*) filter (where is_active = false)::int as inactive_accounts,
  (
    select count(*)::int
    from system.notifications n
    cross join role_ctx
    where role_ctx.role_name = 'superAdmin'
      and n.is_read = false
      and n.type = 'account_created'
  ) as unread_admin_alerts,
  (
    select count(*)::int
    from system.audit_log al
    cross join role_ctx
    where role_ctx.role_name = 'superAdmin'
      and al.entity_type = 'account'
      and al.action in (
        'account_created',
        'account_activated',
        'account_deactivated',
        'permissions_updated'
      )
      and al.created_at >= now() - interval '7 days'
  ) as recent_admin_actions,
  count(*) filter (
    where (
      (
        account_level in (
          'super_admin',
          'platform_admin',
          'office_admin',
          'master_admin',
          'photo_objet_master'
        )
        and scope_type <> 'global'
      )
      or (account_level = 'brand_admin' and scope_type <> 'brand')
      or (
        account_level in ('store_admin', 'photo_objet_store_admin')
        and scope_type <> 'store'
      )
      or (
        scope_type in ('brand', 'store')
        and coalesce(array_length(scope_ids, 1), 0) = 0
      )
      or (
        scope_type in ('brand', 'store')
        and coalesce(array_length(scope_ids, 1), 0) > 1
      )
    )
  )::int as scope_mismatch_signals
from managed_accounts;
alter view dashboard.admin_monitoring_summary_view set (security_invoker = true);
grant select on dashboard.admin_monitoring_summary_view to authenticated;
create or replace view dashboard.admin_monitoring_rows_view as
with role_ctx as (
  select core.current_role() as role_name
),
account_rows as (
  select
    oup.auth_id as entity_id,
    oup.display_name,
    oup.email,
    oup.account_level,
    oup.scope_type,
    oup.scope_ids,
    oup.is_active,
    oup.updated_at,
    case
      when oup.scope_type = 'brand' then oup.scope_ids[1]
      when oup.scope_type = 'store' then st.brand_id
      else null::uuid
    end as scope_brand_id,
    case
      when oup.scope_type = 'store' then oup.scope_ids[1]
      else null::uuid
    end as scope_store_id,
    case
      when oup.scope_type = 'global' then 'Global scope'
      when oup.scope_type = 'brand' then coalesce(b.name, 'Brand scope')
      when oup.scope_type = 'store' then coalesce(st.name, 'Store scope')
      else 'Unspecified scope'
    end::text as scope_label
  from public.office_user_profiles oup
  left join ops.stores st on st.id = oup.scope_ids[1]
  left join ops.brands b on b.id = oup.scope_ids[1]
  cross join role_ctx
  where role_ctx.role_name = 'superAdmin'
),
scope_mismatch_rows as (
  select *
  from account_rows ar
  where (
    (
      ar.account_level in (
        'super_admin',
        'platform_admin',
        'office_admin',
        'master_admin',
        'photo_objet_master'
      )
      and ar.scope_type <> 'global'
    )
    or (ar.account_level = 'brand_admin' and ar.scope_type <> 'brand')
    or (
      ar.account_level in ('store_admin', 'photo_objet_store_admin')
      and ar.scope_type <> 'store'
    )
    or (
      ar.scope_type in ('brand', 'store')
      and coalesce(array_length(ar.scope_ids, 1), 0) = 0
    )
    or (
      ar.scope_type in ('brand', 'store')
      and coalesce(array_length(ar.scope_ids, 1), 0) > 1
    )
  )
)
select
  'inactive_account'::text as row_type,
  ar.entity_id,
  (coalesce(ar.display_name, 'Unnamed account') || ' · ' || coalesce(ar.email, 'no-email'))::text
    as entity_label,
  ar.scope_brand_id,
  ar.scope_store_id,
  ar.scope_label,
  'inactive'::text as status_raw,
  'action_required'::text as status_bucket,
  ar.updated_at as date_value,
  to_char(ar.updated_at, 'DD Mon YYYY HH24:MI')::text as date_label,
  ('/system/accounts/detail?id=' || ar.entity_id)::text as detail_route,
  'Open account detail'::text as detail_route_label
from account_rows ar
where ar.is_active = false

union all

select
  'scope_mismatch'::text as row_type,
  ar.entity_id,
  (coalesce(ar.display_name, 'Unnamed account') || ' · ' || coalesce(ar.email, 'no-email'))::text
    as entity_label,
  ar.scope_brand_id,
  ar.scope_store_id,
  ar.scope_label,
  (ar.account_level || ':' || ar.scope_type)::text as status_raw,
  'action_required'::text as status_bucket,
  ar.updated_at as date_value,
  to_char(ar.updated_at, 'DD Mon YYYY HH24:MI')::text as date_label,
  ('/system/accounts/detail?id=' || ar.entity_id)::text as detail_route,
  'Review account scope'::text as detail_route_label
from scope_mismatch_rows ar

union all

select
  'recent_admin_action'::text as row_type,
  coalesce(al.entity_id, al.actor_id) as entity_id,
  (
    initcap(replace(al.action, '_', ' '))
    || ' · '
    || coalesce(oup.display_name, coalesce(al.entity_id::text, 'Unknown account'))
  )::text as entity_label,
  null::uuid as scope_brand_id,
  null::uuid as scope_store_id,
  'Admin audit log'::text as scope_label,
  al.action::text as status_raw,
  'recent_activity'::text as status_bucket,
  al.created_at as date_value,
  to_char(al.created_at, 'DD Mon YYYY HH24:MI')::text as date_label,
  (
    case
      when al.entity_id is not null
        then '/system/accounts/detail?id=' || al.entity_id
      else '/system/accounts'
    end
  )::text as detail_route,
  (
    case
      when al.entity_id is not null
        then 'Open account detail'
      else 'Open account list'
    end
  )::text as detail_route_label
from system.audit_log al
left join public.office_user_profiles oup on oup.auth_id = al.entity_id
cross join role_ctx
where role_ctx.role_name = 'superAdmin'
  and al.entity_type = 'account'
  and al.action in (
    'account_created',
    'account_activated',
    'account_deactivated',
    'permissions_updated'
  )
  and al.created_at >= now() - interval '30 days'

union all

select
  'unread_admin_alert'::text as row_type,
  coalesce(n.entity_id, n.recipient_id) as entity_id,
  coalesce(n.title, 'Admin alert')::text as entity_label,
  null::uuid as scope_brand_id,
  null::uuid as scope_store_id,
  'Admin notification'::text as scope_label,
  n.type::text as status_raw,
  'attention'::text as status_bucket,
  n.created_at as date_value,
  to_char(n.created_at, 'DD Mon YYYY HH24:MI')::text as date_label,
  '/system/accounts'::text as detail_route,
  'Open account list'::text as detail_route_label
from system.notifications n
cross join role_ctx
where role_ctx.role_name = 'superAdmin'
  and n.is_read = false
  and n.type = 'account_created';
alter view dashboard.admin_monitoring_rows_view set (security_invoker = true);
grant select on dashboard.admin_monitoring_rows_view to authenticated;
