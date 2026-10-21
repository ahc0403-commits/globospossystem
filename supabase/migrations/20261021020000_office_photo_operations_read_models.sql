begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- Read-only, service-only contracts. Office pos-bridge authenticates the Office
-- employee and supplies independent finance/HR/payroll/inventory store scopes.
create function public.office_photo_inventory_page(p_store_id uuid,p_after uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.restaurants r where r.id=p_store_id
   and r.is_active and r.brand_id='77000000-0000-0000-0000-000000000001') then
   raise exception 'PHOTO_STORE_INVALID' using errcode='22023';end if;
 return (select jsonb_build_object('store_id',p_store_id,'observed_at',statement_timestamp(),
   'source','pos_inventory_items','rows',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb))
 from (select i.id,i.restaurant_id as store_id,i.name,i.current_stock,i.unit,
   i.reorder_point,i.updated_at from public.inventory_items i
   where i.restaurant_id=p_store_id and i.is_active and (p_after is null or i.id>p_after)
   order by i.id limit 100)x);
end $$;

-- Selected profile only; no login identifiers or unmasked phone/bank fields.
create function public.office_photo_employee_profile(p_store_id uuid,p_employee_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('store_id',e.store_id,'employee_id',e.id,
   'employee_number',e.employee_number,
   'phone_masked',case when nullif(btrim(e.phone),'') is not null then '••••'||right(e.phone,3) end,
   'bank_name',e.bank_name,
   'bank_account_masked',case when nullif(btrim(e.bank_account_number),'') is not null
     then '••••'||right(e.bank_account_number,4) end,
   'probation_start_date',e.probation_start_date,'employment_start_date',e.employment_start_date,
   'source_updated_at',e.updated_at,'source','pos_workforce')
 from public.store_employees e join public.restaurants r on r.id=e.store_id
 where e.id=p_employee_id and e.store_id=p_store_id and e.is_active
   and r.is_active and r.brand_id='77000000-0000-0000-0000-000000000001'
$$;

create function public.office_photo_operations_report(
 p_store_ids uuid[],p_from date,p_to date,
 p_finance_ids uuid[],p_hr_ids uuid[],p_payroll_ids uuid[],p_inventory_ids uuid[]
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;cutoff timestamptz;
begin
 if p_store_ids is null or cardinality(p_store_ids)>50 or array_position(p_store_ids,null) is not null
   or p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
   or p_to<p_from or p_to-p_from>91
   or p_finance_ids is null or p_hr_ids is null or p_payroll_ids is null or p_inventory_ids is null
   or not(p_finance_ids<@p_store_ids and p_hr_ids<@p_store_ids
     and p_payroll_ids<@p_store_ids and p_inventory_ids<@p_store_ids)
   or array_position(p_finance_ids||p_hr_ids||p_payroll_ids||p_inventory_ids,null) is not null then
   raise exception 'PHOTO_REPORT_SCOPE_INVALID' using errcode='22023';end if;
 if exists(select 1 from unnest(p_store_ids) id where not exists(select 1 from public.restaurants r
   where r.id=id and r.is_active and r.brand_id='77000000-0000-0000-0000-000000000001')) then
   raise exception 'PHOTO_STORE_INVALID' using errcode='22023';end if;
 cutoff:=least(statement_timestamp(),(p_to+1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
 -- Every one-to-many source is grouped before joining the store set. No
 -- employee/store loops, cross-products, or per-row RPCs.
 with stores as materialized(select distinct unnest(p_store_ids) as id),
 sales as (select s.store_id,count(*) as source_rows,sum(s.gross_sales) as sales,
   sum(s.transaction_count) as transactions,max(s.pulled_at) as updated_at
   from public.photo_objet_sales s where s.store_id=any(p_finance_ids)
   and s.sale_date between p_from and p_to group by s.store_id),
 closes as (select c.restaurant_id as store_id,count(*) as days,max(c.closing_date) as last_date,
   sum(c.payments_cash) as cash,sum(c.payments_bank_transfer) as bank_transfer,
   max(c.created_at) as updated_at from public.daily_closings c
   where c.restaurant_id=any(p_finance_ids) and c.closing_date between p_from and p_to
   group by c.restaurant_id),
 orders as (select o.restaurant_id as store_id,count(*) as orders,
   count(*) filter(where o.status='cancelled') as cancelled_orders from public.orders o
   where o.restaurant_id=any(p_finance_ids)
   and o.created_at >= p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'
   and o.created_at < (p_to+1)::timestamp at time zone 'Asia/Ho_Chi_Minh' group by o.restaurant_id),
 adjustments as (select a.restaurant_id as store_id,
   sum(a.amount) filter(where a.adjustment_type='void') as void_amount,
   sum(a.amount) filter(where a.adjustment_type='refund') as refund_amount,count(*) as source_rows
   from public.payment_adjustments a where a.restaurant_id=any(p_finance_ids)
   and a.created_at >= p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'
   and a.created_at < (p_to+1)::timestamp at time zone 'Asia/Ho_Chi_Minh' group by a.restaurant_id),
 last_clock_events as materialized(select distinct on(l.restaurant_id,l.employee_id)
   l.restaurant_id,l.employee_id,l.type,l.logged_at from public.attendance_logs l
   where l.restaurant_id=any(p_hr_ids) and l.employee_id is not null and l.logged_at<cutoff
   order by l.restaurant_id,l.employee_id,l.logged_at desc,l.id desc),
 photo_employees as materialized(select id,store_id,full_name from public.store_employees
   where store_id=any(p_hr_ids) and is_active),
 latest_events as materialized(select l.*,e.full_name from last_clock_events l
   join photo_employees e on e.id=l.employee_id and e.store_id=l.restaurant_id),
 ranked_events as (select *,row_number() over(partition by restaurant_id order by (type='clock_in') desc,full_name,employee_id) as display_rank from latest_events),
 attendance as (select restaurant_id as store_id,count(*) filter(where type='clock_in') as working,
   min(logged_at) filter(where type='clock_in') as earliest_open_clock_in,
   coalesce(jsonb_agg(jsonb_build_object('employee_id',employee_id,'name',full_name,'clocked_in_at',logged_at) order by full_name,employee_id) filter(where type='clock_in' and display_rank<=20),'[]'::jsonb) as staff
   from ranked_events group by restaurant_id),
 inventory_rows as materialized(select i.*,row_number() over(partition by restaurant_id order by (current_stock<=0) desc nulls last,(current_stock<=reorder_point) desc nulls last,id) as display_rank
   from public.inventory_items i where i.restaurant_id=any(p_inventory_ids) and i.is_active),
 inventory as (select i.restaurant_id as store_id,count(*) as items,
   count(*) filter(where i.current_stock<=0) as out_of_stock,
   count(*) filter(where i.current_stock>0 and i.reorder_point is not null
     and i.current_stock<=i.reorder_point) as low_stock,
   count(*) filter(where i.current_stock is null) as unrecorded,
   max(i.updated_at) as updated_at,
   coalesce(jsonb_agg(jsonb_build_object('item_id',i.id,'name',i.name,'quantity',i.current_stock,'unit',i.unit,'reorder_point',i.reorder_point) order by i.display_rank) filter(where (i.current_stock<=0 or i.current_stock<=i.reorder_point) and i.display_rank<=20),'[]'::jsonb) as alerts
   from inventory_rows i group by i.restaurant_id),
 payroll as (select p.restaurant_id as store_id,count(*) as records,sum(p.total_amount) as total,
   max(p.updated_at) as updated_at from public.payroll_records p
   where p.restaurant_id=any(p_payroll_ids) and p.period_start=p_from and p.period_end=p_to
   and p.status='confirmed' group by p.restaurant_id)
 select jsonb_build_object('version',1,'from',p_from,'to',p_to,'observed_at',statement_timestamp(),
   'attendance_as_of',cutoff,'rows',coalesce(jsonb_agg(jsonb_build_object('store_id',s.id,
   'finance',case when s.id=any(p_finance_ids) then jsonb_build_object(
     'sales',sales.sales,'transactions',sales.transactions,'sales_source_rows',coalesce(sales.source_rows,0),
     'sales_updated_at',sales.updated_at,'cash',closes.cash,'bank_transfer',closes.bank_transfer,
     'closing_days',coalesce(closes.days,0),'last_closing_date',closes.last_date,
     'closing_updated_at',closes.updated_at,'orders',coalesce(orders.orders,0),
     'cancelled_orders',coalesce(orders.cancelled_orders,0),
     'void_amount',coalesce(adjustments.void_amount,0),'refund_amount',coalesce(adjustments.refund_amount,0)) end,
   'attendance',case when s.id=any(p_hr_ids) then jsonb_build_object(
     'working',coalesce(attendance.working,0),'earliest_open_clock_in',attendance.earliest_open_clock_in,'staff',coalesce(attendance.staff,'[]'::jsonb)) end,
   'inventory',case when s.id=any(p_inventory_ids) then jsonb_build_object(
     'items',coalesce(inventory.items,0),'out_of_stock',inventory.out_of_stock,
     'low_stock',inventory.low_stock,'unrecorded',inventory.unrecorded,'updated_at',inventory.updated_at,'alerts',coalesce(inventory.alerts,'[]'::jsonb)) end,
   'payroll',case when s.id=any(p_payroll_ids) then jsonb_build_object(
     'records',coalesce(payroll.records,0),'total',payroll.total,'updated_at',payroll.updated_at) end
   ) order by s.id),'[]'::jsonb)) into result from stores s
 left join sales on sales.store_id=s.id left join closes on closes.store_id=s.id
 left join orders on orders.store_id=s.id left join adjustments on adjustments.store_id=s.id
 left join attendance on attendance.store_id=s.id left join inventory on inventory.store_id=s.id
 left join payroll on payroll.store_id=s.id;
 return result;
end $$;

revoke all on function public.office_photo_inventory_page(uuid,uuid),
 public.office_photo_employee_profile(uuid,uuid),
 public.office_photo_operations_report(uuid[],date,date,uuid[],uuid[],uuid[],uuid[])
 from public,anon,authenticated;
grant execute on function public.office_photo_inventory_page(uuid,uuid),
 public.office_photo_employee_profile(uuid,uuid),
 public.office_photo_operations_report(uuid[],date,date,uuid[],uuid[],uuid[],uuid[]) to service_role;

-- production-gate: self-verifying
do $$begin
 if has_function_privilege('authenticated','public.office_photo_operations_report(uuid[],date,date,uuid[],uuid[],uuid[],uuid[])','EXECUTE')
   or has_function_privilege('anon','public.office_photo_employee_profile(uuid,uuid)','EXECUTE')
   or not has_function_privilege('service_role','public.office_photo_inventory_page(uuid,uuid)','EXECUTE') then
   raise exception 'PHOTO_READ_MODEL_ACL_INVALID';end if;
end $$;
notify pgrst,'reload schema';
commit;
