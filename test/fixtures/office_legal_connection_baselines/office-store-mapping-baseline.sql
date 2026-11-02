CREATE OR REPLACE FUNCTION ops.connect_verified_pos_stores(p_rows jsonb, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege;end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>200
    or not exists(select 1 from public.office_user_profiles p where p.auth_id=p_actor_id
      and p.credential_state='active' and p.is_active and not p.is_suspended
      and p.account_level in ('platform_admin','super_admin')
      and (p.permission_model_version in ('v1','v2_shadow') or exists(
        select 1 from core.office_access_grants g where g.user_profile_id=p.id
          and g.domain='system' and g.action='admin' and g.scope_level='group'
          and g.is_active and g.revoked_at is null and g.valid_from<=now()
          and (g.valid_until is null or g.valid_until>now())))) then
    raise exception 'POS_STORE_MAPPING_FORBIDDEN';end if;
  perform pg_advisory_xact_lock(hashtextextended('office_verified_pos_store_mapping',0));
  with rows as materialized (
    select * from jsonb_to_recordset(p_rows) x(store_id uuid,store_name text,brand_id uuid,
      brand_name text,tax_entity_id uuid,is_active boolean)
  ), anchors as materialized (
    select x.tax_entity_id,min(s.legal_entity_id::text)::uuid legal_entity_id
    from rows x join ops.stores s on s.pos_store_id=x.store_id
    where s.status='active' and s.legal_entity_id is not null and x.is_active
      and x.tax_entity_id is not null
      and (s.pos_tax_entity_id is null or s.pos_tax_entity_id=x.tax_entity_id::text)
    group by x.tax_entity_id having count(distinct s.legal_entity_id)=1
  ), brand_anchors as materialized (
    select x.brand_id,min(s.brand_id::text)::uuid office_brand_id
    from rows x join ops.stores s on s.pos_store_id=x.store_id
    where s.brand_id is not null group by x.brand_id having count(distinct s.brand_id)=1
  ), linked_brands as (
    update ops.brands b set pos_brand_id=a.brand_id from brand_anchors a
    where b.id=a.office_brand_id and b.pos_brand_id is null
      and not exists(select 1 from ops.brands other where other.pos_brand_id=a.brand_id)
    returning b.id,b.pos_brand_id
  ), new_brands as (
    insert into ops.brands(name,status,pos_brand_id)
    select distinct x.brand_name,'active'::core.account_status,x.brand_id from rows x join anchors a using(tax_entity_id)
    where x.is_active and x.brand_id is not null and nullif(trim(x.brand_name),'') is not null
      and not exists(select 1 from brand_anchors b where b.brand_id=x.brand_id)
      and not exists(select 1 from ops.brands b where b.pos_brand_id=x.brand_id)
    on conflict(pos_brand_id) where pos_brand_id is not null do nothing returning id,pos_brand_id
  ), brand_map as materialized (
    select office_brand_id id,brand_id pos_brand_id from brand_anchors
    union select id,pos_brand_id from new_brands
    union select id,pos_brand_id from ops.brands where pos_brand_id is not null
  ), entity_brands as (
    insert into ops.legal_entity_brands(legal_entity_id,brand_id)
    select distinct a.legal_entity_id,b.id from rows x join anchors a using(tax_entity_id)
      join brand_map b on b.pos_brand_id=x.brand_id
    on conflict do nothing returning brand_id
  ) select jsonb_build_object('created_brand_count',(select count(*) from new_brands),
    'linked_brand_count',(select count(*) from linked_brands),
    'linked_entity_brand_count',(select count(*) from entity_brands)) into r;
  -- Separate statements make the validated legal-entity/brand relationship
  -- visible to the existing store integrity trigger before store creation.
  with rows as materialized (
    select * from jsonb_to_recordset(p_rows) x(store_id uuid,store_name text,brand_id uuid,
      brand_name text,tax_entity_id uuid,is_active boolean)
  ), anchors as materialized (
    select x.tax_entity_id,min(s.legal_entity_id::text)::uuid legal_entity_id
    from rows x join ops.stores s on s.pos_store_id=x.store_id
    where s.status='active' and s.legal_entity_id is not null and x.is_active and x.tax_entity_id is not null
      and (s.pos_tax_entity_id is null or s.pos_tax_entity_id=x.tax_entity_id::text)
    group by x.tax_entity_id having count(distinct s.legal_entity_id)=1
  ), connected as (
    insert into ops.stores(name,status,brand_id,legal_entity_id,pos_store_id,pos_tax_entity_id)
    select x.store_name,'active'::core.account_status,b.id,a.legal_entity_id,x.store_id,x.tax_entity_id
    from rows x join anchors a using(tax_entity_id) join ops.brands b on b.pos_brand_id=x.brand_id
    where x.is_active and nullif(trim(x.store_name),'') is not null
      and not exists(select 1 from ops.stores s where s.pos_store_id=x.store_id)
    on conflict do nothing returning id
  ) select r||jsonb_build_object('created_store_count',count(*)) into r from connected;
  insert into system.audit_log(actor_id,action,entity_type,detail)
    values(p_actor_id,'connect_verified_pos_stores','store_mapping',r);
  return r;
end $function$

