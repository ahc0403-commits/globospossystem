begin;

-- Office actors remain Office identities. No POS user or Auth impersonation.
alter table public.inventory_items add column if not exists office_revision bigint not null default 0;
alter table public.inventory_items add column if not exists office_tracking_enabled boolean not null default true;
alter table public.inventory_items add column if not exists office_target_stock numeric(12,3);
update public.inventory_items i set office_tracking_enabled=false
from public.restaurants r where r.id=i.restaurant_id and r.brand_id='77000000-0000-0000-0000-000000000001'
and lower(btrim(i.name)) in ('pen','bút','sticker');

create table public.office_photo_inventory_requests (
 request_id uuid primary key, office_actor_id uuid not null, store_id uuid not null references public.restaurants(id),
 item_id uuid not null references public.inventory_items(id), payload jsonb not null,
 result jsonb not null, created_at timestamptz not null default now()
);
alter table public.office_photo_inventory_requests enable row level security;
revoke all on public.office_photo_inventory_requests from public,anon,authenticated;

create function public.office_photo_inventory_revision() returns trigger language plpgsql set search_path='' as $$
begin new.office_revision:=old.office_revision+1; return new; end $$;
create trigger office_photo_inventory_revision before update on public.inventory_items
for each row execute function public.office_photo_inventory_revision();
create index office_photo_inventory_page_idx on public.inventory_items(restaurant_id,id) where is_active and office_tracking_enabled;

create function public.office_photo_stock_page(p_store_ids uuid[],p_after uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if p_store_ids is null or cardinality(p_store_ids) not between 1 and 50 or exists(
 select 1 from unnest(p_store_ids) x left join public.restaurants r on r.id=x
 where r.id is null or not r.is_active or r.brand_id<>'77000000-0000-0000-0000-000000000001') then
 raise exception 'PHOTO_SCOPE_DENIED' using errcode='42501'; end if;
 select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb),'observed_at',statement_timestamp()) into result
 from (select i.id,i.restaurant_id as store_id,i.name,i.unit,i.current_stock as quantity,
 i.reorder_point,i.office_target_stock as target_stock,i.updated_at,i.office_revision as revision
 from public.inventory_items i where i.restaurant_id=any(p_store_ids) and i.is_active and i.office_tracking_enabled
 and (p_after is null or i.id>p_after) order by i.id limit 100) x;
 return result;
end $$;

-- Explicit service-only command; bridge verifies the actual Office actor's
-- inventory:edit store grant. Current-day counts share the POS count history.
create function public.office_photo_stock_count(p_store_id uuid,p_item_id uuid,p_quantity numeric,
 p_expected_revision bigint,p_request_id uuid,p_office_actor_id uuid,p_reason text,
 p_reorder_point numeric default null,p_target_stock numeric default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item public.inventory_items%rowtype; prior public.inventory_physical_counts%rowtype;
 saved public.office_photo_inventory_requests%rowtype; payload jsonb; result jsonb; count_id uuid;
 today date:=(now() at time zone 'Asia/Ho_Chi_Minh')::date; baseline numeric; previous numeric;
begin
 if p_office_actor_id is null or p_request_id is null or p_expected_revision is null
 or p_quantity is null or p_quantity<0 or p_quantity>999999999 or p_quantity<>round(p_quantity,3)
 or p_quantity::text in ('NaN','Infinity','-Infinity')
 or (p_reorder_point is not null and (p_reorder_point<0 or p_reorder_point>999999999 or p_reorder_point<>round(p_reorder_point,3)))
 or (p_target_stock is not null and (p_target_stock<0 or p_target_stock>999999999 or p_target_stock<>round(p_target_stock,3)))
 or (p_target_stock is not null and p_reorder_point is not null and p_target_stock<p_reorder_point)
 or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'PHOTO_INVALID_CHANGE' using errcode='22023'; end if;
 payload:=jsonb_build_object('store',p_store_id,'item',p_item_id,'quantity',p_quantity,'revision',p_expected_revision,
 'reason',btrim(p_reason),'reorder',p_reorder_point,'target',p_target_stock);
 perform pg_advisory_xact_lock(hashtextextended('office-photo-count:'||p_request_id::text,0));
 select * into saved from public.office_photo_inventory_requests where request_id=p_request_id;
 if found then
  if saved.office_actor_id<>p_office_actor_id or saved.payload<>payload then raise exception 'PHOTO_REQUEST_REUSED' using errcode='22023'; end if;
  return saved.result;
 end if;
 select i.* into item from public.inventory_items i join public.restaurants r on r.id=i.restaurant_id
 where i.id=p_item_id and i.restaurant_id=p_store_id and i.is_active and i.office_tracking_enabled
 and r.is_active and r.brand_id='77000000-0000-0000-0000-000000000001' for update of i;
 if not found then raise exception 'PHOTO_SCOPE_DENIED' using errcode='42501'; end if;
 if item.office_revision<>p_expected_revision then raise exception 'PHOTO_INVENTORY_CONFLICT' using errcode='40001'; end if;
 select * into prior from public.inventory_physical_counts where restaurant_id=p_store_id and ingredient_id=p_item_id and count_date=today for update;
 previous:=coalesce(prior.actual_quantity_g,item.current_stock,0);
 baseline:=coalesce(prior.theoretical_quantity_g,item.current_stock,0);
 insert into public.inventory_physical_counts(restaurant_id,ingredient_id,count_date,actual_quantity_g,theoretical_quantity_g,variance_g,note,updated_at)
 values(p_store_id,p_item_id,today,p_quantity,baseline,p_quantity-baseline,btrim(p_reason),now())
 on conflict(ingredient_id,count_date) do update set actual_quantity_g=excluded.actual_quantity_g,
 variance_g=excluded.actual_quantity_g-coalesce(inventory_physical_counts.theoretical_quantity_g,excluded.theoretical_quantity_g),
 counted_by=null,note=excluded.note,updated_at=now() returning id into count_id;
 update public.inventory_items set current_stock=p_quantity,reorder_point=p_reorder_point,office_target_stock=p_target_stock,updated_at=now()
 where id=p_item_id returning * into item;
 insert into public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,stock_before,stock_after,effective_date)
 values(p_store_id,p_item_id,'adjust',p_quantity-previous,'physical_count',count_id,btrim(p_reason),previous,p_quantity,today);
 result:=jsonb_build_object('id',item.id,'store_id',item.restaurant_id,'name',item.name,'unit',item.unit,
 'quantity',item.current_stock,'reorder_point',item.reorder_point,'target_stock',item.office_target_stock,'updated_at',item.updated_at,'revision',item.office_revision);
 insert into public.office_photo_inventory_requests(request_id,office_actor_id,store_id,item_id,payload,result)
 values(p_request_id,p_office_actor_id,p_store_id,p_item_id,payload,result);
 return result;
end $$;

create function public.office_photo_on_shift(p_store_ids uuid[],p_after uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if p_store_ids is null or cardinality(p_store_ids) not between 1 and 50 or exists(
 select 1 from unnest(p_store_ids) x left join public.restaurants r on r.id=x
 where r.id is null or not r.is_active or r.brand_id<>'77000000-0000-0000-0000-000000000001') then
 raise exception 'PHOTO_SCOPE_DENIED' using errcode='42501';end if;
 return (with latest as (
 select distinct on(l.employee_id) l.employee_id,l.restaurant_id,l.type,l.logged_at
 from public.attendance_logs l where l.restaurant_id=any(p_store_ids)
 and l.logged_at>=statement_timestamp()-interval '36 hours' and l.logged_at<=statement_timestamp()
 and l.employee_id is not null order by l.employee_id,l.logged_at desc,l.id desc
 ), rows as(select e.id,e.full_name,l.restaurant_id as store_id,l.logged_at as clock_in,
 l.logged_at<statement_timestamp()-interval '18 hours' as needs_review
 from latest l join public.store_employees e on e.id=l.employee_id and e.store_id=l.restaurant_id and e.is_active
 where l.type='clock_in' and (p_after is null or e.id>p_after) order by e.id limit 100)
 select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(rows) order by id),'[]'::jsonb),'observed_at',statement_timestamp()) from rows);
end $$;

revoke all on function public.office_photo_stock_page(uuid[],uuid),public.office_photo_stock_count(uuid,uuid,numeric,bigint,uuid,uuid,text,numeric,numeric),public.office_photo_on_shift(uuid[],uuid) from public,anon,authenticated;
grant execute on function public.office_photo_stock_page(uuid[],uuid),public.office_photo_stock_count(uuid,uuid,numeric,bigint,uuid,uuid,text,numeric,numeric),public.office_photo_on_shift(uuid[],uuid) to service_role;

-- Version clocks detect edits between bounded payroll pages without fetching
-- all attendance rows again. Incremented by existing POS writes as well.
create table public.office_photo_source_versions(store_id uuid primary key references public.restaurants(id),version bigint not null default 0);
insert into public.office_photo_source_versions(store_id) select id from public.restaurants where brand_id='77000000-0000-0000-0000-000000000001';
alter table public.office_photo_source_versions enable row level security;
revoke all on public.office_photo_source_versions from public,anon,authenticated;
create function public.office_photo_source_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare before_id uuid; after_id uuid;
begin
 if tg_op<>'INSERT' then before_id:=(to_jsonb(old)->>tg_argv[0])::uuid;end if;
 if tg_op<>'DELETE' then after_id:=(to_jsonb(new)->>tg_argv[0])::uuid;end if;
 update public.office_photo_source_versions set version=version+1 where store_id in(before_id,after_id);
 return null;
end $$;
create trigger office_photo_source_changed after insert or update or delete on public.attendance_logs for each row execute function public.office_photo_source_changed('restaurant_id');
create trigger office_photo_source_changed after insert or update or delete on public.store_employees for each row execute function public.office_photo_source_changed('store_id');
create trigger office_photo_source_changed after insert or update or delete on public.employee_hourly_pay_rules for each row execute function public.office_photo_source_changed('store_id');
create trigger office_photo_source_changed after insert or update or delete on public.employee_daily_allowances for each row execute function public.office_photo_source_changed('store_id');
create function public.office_photo_holidays_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin update public.office_photo_source_versions set version=version+1;return null;end $$;
create trigger office_photo_holidays_changed after insert or update or delete on public.vietnam_public_holidays for each statement execute function public.office_photo_holidays_changed();

create table public.office_photo_pay_policies (
 store_id uuid not null references public.restaurants(id), effective_from date not null,
 monthly_salary numeric not null default 6500000 check(monthly_salary>0),
 standard_monthly_minutes integer not null default 12480 check(standard_monthly_minutes between 60 and 44640),
 overtime_multiplier numeric not null default 1.5 check(overtime_multiplier>=1),
 office_actor_id uuid,reason text not null,created_at timestamptz not null default now(),primary key(store_id,effective_from)
);
alter table public.office_photo_pay_policies enable row level security;
revoke all on public.office_photo_pay_policies from public,anon,authenticated;
insert into public.office_photo_pay_policies(store_id,effective_from,reason)
select id,date '2000-01-01','Owner confirmed initial 208-hour basis on 2026-10-23' from public.restaurants where brand_id='77000000-0000-0000-0000-000000000001';
create trigger office_photo_source_changed after insert or update or delete on public.office_photo_pay_policies for each row execute function public.office_photo_source_changed('store_id');
create function public.office_photo_pay_policy(p_store_id uuid,p_effective_from date default null,p_monthly_minutes integer default null,p_actor uuid default null,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.restaurants where id=p_store_id and is_active and brand_id='77000000-0000-0000-0000-000000000001') then raise exception 'PHOTO_SCOPE_DENIED';end if;
 if p_monthly_minutes is not null then
  if p_actor is null or p_effective_from is null or p_effective_from<(date_trunc('month',now() at time zone 'Asia/Ho_Chi_Minh')+interval '1 month')::date
   or extract(day from p_effective_from)<>1 or p_monthly_minutes not between 60 and 44640
   or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'PHOTO_PAY_POLICY_INVALID';end if;
  -- Immutable versions; concurrent/repeated writes cannot overwrite old periods.
  insert into public.office_photo_pay_policies(store_id,effective_from,standard_monthly_minutes,office_actor_id,reason)
  values(p_store_id,p_effective_from,p_monthly_minutes,p_actor,btrim(p_reason)) on conflict(store_id,effective_from) do nothing;
  if not exists(select 1 from public.office_photo_pay_policies where store_id=p_store_id and effective_from=p_effective_from and standard_monthly_minutes=p_monthly_minutes) then raise exception 'PHOTO_PAY_POLICY_CONFLICT' using errcode='40001';end if;
 end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('effective_from',effective_from,'monthly_salary',monthly_salary,'standard_monthly_minutes',standard_monthly_minutes,'overtime_multiplier',overtime_multiplier) order by effective_from desc),'[]'::jsonb) from public.office_photo_pay_policies where store_id=p_store_id);
end $$;
revoke all on function public.office_photo_pay_policy(uuid,date,integer,uuid,text) from public,anon,authenticated;
grant execute on function public.office_photo_pay_policy(uuid,date,integer,uuid,text) to service_role;

-- Owner-confirmed attendance proration, initially 208 standard hours/month.
-- Future-effective versions preserve the previous period basis.
-- Private projection: only security-definer financial-input RPCs use this view.
create view public.v_financial_payroll_staff with(security_barrier=true) as
with policies as(select store_id,jsonb_agg(jsonb_build_object('effective_from',effective_from,'monthly_salary',monthly_salary,
 'standard_monthly_minutes',standard_monthly_minutes,'overtime_multiplier',overtime_multiplier) order by effective_from desc) as pay_policies
 from public.office_photo_pay_policies group by store_id)
select e.*,r.brand_id='77000000-0000-0000-0000-000000000001' as photo_policy,p.pay_policies
from public.store_employees e join public.restaurants r on r.id=e.store_id left join policies p on p.store_id=e.store_id;
revoke all on public.v_financial_payroll_staff from public,anon,authenticated;
-- Preserve the existing financial-input authorization, paging and revisions.
do $$ declare f record; definition text; changed text; begin
 for f in select oid from pg_proc where pronamespace='public'::regnamespace and proname in('get_financial_input_page','get_employee_financial_input_page') loop
  definition:=pg_get_functiondef(f.oid);
  changed:=replace(definition,'SELECT id, store_id, employee_number, full_name, employment_role','SELECT id, store_id, employee_number, full_name, employment_role, employment_start_date, photo_policy, pay_policies');
  changed:=replace(changed,'FROM public.store_employees WHERE store_id = ANY($1)','FROM public.v_financial_payroll_staff WHERE store_id = ANY($1)');
  if changed=definition then raise exception 'PHOTO_FINANCIAL_STAFF_CONTRACT_CHANGED';end if;
  execute changed;
 end loop;
end $$;

create function public.office_photo_payroll_batch(p_store_ids uuid[],p_from date,p_to date,
 p_after uuid default null,p_employee_id uuid default null,p_expected_version jsonb default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; versions jsonb;
begin
 if p_store_ids is null or cardinality(p_store_ids) not between 1 and 50 or p_from is null or p_to is null
 or not isfinite(p_from) or not isfinite(p_to) or p_to<p_from or p_to-p_from>91
 or exists(select 1 from unnest(p_store_ids) x left join public.restaurants r on r.id=x
 where r.id is null or not r.is_active or r.brand_id<>'77000000-0000-0000-0000-000000000001') then raise exception 'PAYROLL_INPUT_QUERY_INVALID';end if;
 select jsonb_object_agg(store_id,version) into versions from public.office_photo_source_versions where store_id=any(p_store_ids);
 if p_expected_version is not null and p_expected_version<>versions then raise exception 'PAYROLL_INPUT_CHANGED' using errcode='40001';end if;
 with candidates as materialized (
 select e.id,e.store_id,e.employee_number,e.full_name,e.employment_role,e.employment_start_date
 from public.store_employees e where e.store_id=any(p_store_ids) and e.is_active
 and e.employment_role in('part_timer','full_time') and (p_after is null or e.id>p_after)
 and (p_employee_id is null or e.id=p_employee_id) order by e.id limit 26
 ), staff as materialized(select * from candidates order by id limit 25),
 logs as materialized(select l.id,l.restaurant_id,l.employee_id,l.type,l.logged_at,s.full_name,s.employment_role
 from public.attendance_logs l join staff s on s.id=l.employee_id and s.store_id=l.restaurant_id
 where l.logged_at>=(p_from::timestamp at time zone 'Asia/Ho_Chi_Minh')
 and l.logged_at<((p_to+1)::timestamp at time zone 'Asia/Ho_Chi_Minh') order by l.logged_at,l.id limit 5001),
 grouped_logs as(select employee_id,jsonb_agg(jsonb_build_object('id',id,'restaurant_id',restaurant_id,'employee_id',employee_id,
 'user_id',employee_id,'type',type,'logged_at',logged_at,'users',jsonb_build_object('id',employee_id,'full_name',full_name,'role',employment_role)) order by logged_at,id) rows
 from logs group by employee_id),
 grouped_allowances as(select a.employee_id,jsonb_agg(jsonb_build_object('id',a.id,'store_id',a.store_id,'employee_id',a.employee_id,
 'work_date',a.work_date,'is_split_shift',a.is_split_shift,'meal_allowance_amount',a.meal_allowance_amount,'parking_allowance_amount',a.parking_allowance_amount) order by a.work_date) rows
 from public.employee_daily_allowances a join staff s on s.id=a.employee_id and s.store_id=a.store_id
 where a.work_date between p_from and p_to group by a.employee_id),
 holidays as(select coalesce(jsonb_agg(holiday_date order by holiday_date),'[]'::jsonb) rows
 from public.vietnam_public_holidays where is_active and holiday_date between p_from and p_to),
 snapshots as(select s.id,jsonb_build_object('version',1,'store_id',s.store_id,'employee_id',s.id,'from',p_from,'to',p_to,
 'generated_at',statement_timestamp(),'staff',jsonb_build_array(jsonb_build_object('user_id',s.id,'employee_number',s.employee_number,
 'full_name',s.full_name,'role',s.employment_role,'photo_policy',true,'employment_start_date',s.employment_start_date,
 'pay_policies',policies.rows)),
 'logs',coalesce(l.rows,'[]'::jsonb),'allowances',coalesce(a.rows,'[]'::jsonb),'holidays',h.rows,
 'hourly_rules',jsonb_build_object(s.id,case when r.employee_id is null or s.employment_role<>'part_timer' then null
 else jsonb_build_object('hourly_rate',r.hourly_rate,'scheduled_start',r.scheduled_start,'night_start',r.night_start,
 'night_multiplier',r.night_multiplier,'holiday_multiplier',r.holiday_multiplier,'exclude_sunday',false,
 'late_threshold_minutes',r.late_threshold_minutes,'late_review_hourly_multiplier',r.late_review_hourly_multiplier) end)) as input
 from staff s left join (select store_id,jsonb_agg(jsonb_build_object('effective_from',effective_from,'monthly_salary',monthly_salary,
 'standard_monthly_minutes',standard_monthly_minutes,'overtime_multiplier',overtime_multiplier) order by effective_from desc) as rows
 from public.office_photo_pay_policies where store_id=any(p_store_ids) group by store_id) policies on policies.store_id=s.store_id
 left join grouped_logs l on l.employee_id=s.id left join grouped_allowances a on a.employee_id=s.id
 left join public.employee_hourly_pay_rules r on r.employee_id=s.id and r.store_id=s.store_id cross join holidays h)
 select jsonb_build_object('inputs',coalesce((select jsonb_agg(input order by id) from snapshots),'[]'::jsonb),
 'has_more',(select count(*)>25 from candidates),'source_version',versions,'observed_at',statement_timestamp(),
 'log_count',(select count(*) from logs)) into result;
 if (result->>'log_count')::integer>5000 then raise exception 'PAYROLL_INPUT_LIMIT_EXCEEDED';end if;
 return result;
end $$;
-- Single-employee and batch screens use the very same snapshot projection.
create or replace function public.office_photo_payroll_inputs(p_store_id uuid,p_employee_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare page jsonb;begin
 page:=public.office_photo_payroll_batch(array[p_store_id],p_from,p_to,null,p_employee_id,null);
 if jsonb_array_length(page->'inputs')<>1 then raise exception 'PAYROLL_EMPLOYEE_NOT_FOUND';end if;
 return page->'inputs'->0;
end $$;
revoke all on function public.office_photo_payroll_batch(uuid[],date,date,uuid,uuid,jsonb),public.office_photo_payroll_inputs(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function public.office_photo_payroll_batch(uuid[],date,date,uuid,uuid,jsonb),public.office_photo_payroll_inputs(uuid,uuid,date,date) to service_role;
commit;
