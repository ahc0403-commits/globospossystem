begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();

insert into public.inventory_items(id,restaurant_id,name,unit,current_stock,cost_per_unit,is_active,updated_at)
select md5('item-'||n)::uuid,md5('store-'||(n%3))::uuid,'Item '||n,'g',1000+n,12,n%2=0,'2026-09-30Z'::timestamptz
from generate_series(1,2500) n;
insert into public.inventory_transactions(ingredient_id,restaurant_id,quantity_g,effective_date,created_at)
select id,restaurant_id,amount,day,'2026-10-01Z'::timestamptz
from public.inventory_items cross join (values(100,'2026-09-01'::date),(-25,'2026-09-15'::date),(30,'2026-10-03'::date)) t(amount,day);
insert into public.inventory_products(id,inventory_item_id,product_code,category,is_active,updated_at)
select md5(item.id::text||n)::uuid,item.id,'SKU-'||n,'food',n=2,'2026-09-30Z'::timestamptz
from public.inventory_items item cross join generate_series(1,2) n;
insert into public.photo_objet_sales_pull_runs(id,store_id,target_date,status,started_at)
select md5('run-'||n||'-'||s)::uuid,md5('store-'||s)::uuid,'2026-09-01'::date+n,'success','2026-09-01Z'::timestamptz+n*interval '1 day'
from generate_series(0,2) s cross join generate_series(0,5) n;
insert into public.inventory_suppliers(id,supplier_name) values (md5('supplier')::uuid,'Test supplier');
insert into public.inventory_purchase_orders(id,purchase_order_no,restaurant_id,brand_id,supplier_id,status,requested_delivery_date,total_supply_amount,tax_amount,total_amount,created_at,updated_at)
select md5('purchase-'||n)::uuid,'PO-'||n,md5('store-'||(n%3))::uuid,md5('brand')::uuid,md5('supplier')::uuid,
 case when n%2=0 then 'received' else 'draft' end,'2026-10-01',100,10,110,'2026-09-30Z'::timestamptz + n*interval '1 second','2026-09-30Z'::timestamptz
from generate_series(1,1500) n;
insert into public.inventory_purchase_order_lines(id,purchase_order_id,product_id,ordered_quantity_base,created_at,updated_at)
select md5('purchase-line-'||n)::uuid,md5('purchase-'||n)::uuid,
  (select id from public.inventory_products order by id limit 1),10,'2026-10-01Z','2026-10-01Z'
from generate_series(1,2) n;
insert into public.inventory_receipts(id,purchase_order_id,restaurant_id,status,received_at,created_at,updated_at)
select md5('receipt-'||n)::uuid,md5('purchase-'||n)::uuid,
  md5('store-'||(n%3))::uuid,'confirmed','2026-10-02Z','2026-10-02Z','2026-10-02Z'
from generate_series(1,2) n;
insert into public.inventory_receipt_lines(id,receipt_id,purchase_order_line_id,product_id,received_quantity_base,accepted_quantity_base,final_supply_amount,created_at,updated_at)
select md5('receipt-line-'||n)::uuid,md5('receipt-'||n)::uuid,
  md5('purchase-line-'||n)::uuid,(select id from public.inventory_products order by id limit 1),10,10,100,'2026-10-02Z','2026-10-02Z'
from generate_series(1,2) n;
insert into public.inventory_supplier_returns(id,purchase_order_id,receipt_line_id,quantity_base)
values(md5('return-1')::uuid,md5('purchase-1')::uuid,md5('receipt-line-1')::uuid,2);
grant usage on schema extensions to service_role;
set local role service_role;
set local request.jwt.claim.role = 'service_role';
select set_eq(
 $$select value from jsonb_array_elements(office_inventory_nxt_snapshots_batch(array[md5('store-0')::uuid,md5('store-1')::uuid],'2026-09-01','2026-09-30')->'rows')$$,
 $$select to_jsonb(t) from (select * from office_get_inventory_nxt_snapshot(md5('store-0')::uuid,'2026-09-01','2026-09-30') union all select * from office_get_inventory_nxt_snapshot(md5('store-1')::uuid,'2026-09-01','2026-09-30')) t$$,
 'batched inventory preserves original quantities, product choice, costs and timestamps across stores');
select ok(jsonb_array_length(office_inventory_nxt_snapshots_batch(array[md5('store-0')::uuid,md5('store-1')::uuid],'2026-09-01','2026-09-30')->'rows')>1000,'JSON snapshot retains all items beyond REST row cap');
select is(office_inventory_nxt_snapshots_batch(array[]::uuid[],'2026-09-01','2026-09-30'),'{"rows":[]}'::jsonb,'empty stores return no inventory');
select throws_like($$select office_inventory_nxt_snapshots_batch(array[md5('store-0')::uuid],'2026-10-01','2026-09-30')$$,'%INVENTORY_NXT_PERIOD_INVALID%','invalid period rejected');
select throws_like($$select office_inventory_nxt_snapshots_batch(array_fill(md5('store-0')::uuid,array[101]),'2026-09-01','2026-09-30')$$,'%INVENTORY_NXT_PERIOD_REQUIRED%','oversized store batch rejected');
select is(jsonb_array_length(office_photo_collection_history_batch(array[md5('store-0')::uuid,md5('store-1')::uuid],'2026-09-01','2026-09-04')->'rows'),2,'history returns one latest row per requested store');
select ok((select bool_and(value->>'target_date'='2026-09-04') from jsonb_array_elements(office_photo_collection_history_batch(array[md5('store-0')::uuid,md5('store-1')::uuid],'2026-09-01','2026-09-04')->'rows')),'latest history is within requested range, not latest overall');
select is(office_photo_collection_history_batch(array[md5('missing')::uuid],'2026-09-01','2026-09-04'),'{"rows":[]}'::jsonb,'missing history is not synthesized');
select ok(not has_function_privilege('authenticated','office_inventory_nxt_snapshots_batch(uuid[],date,date)','execute') and not has_function_privilege('anon','office_photo_collection_history_batch(uuid[],date,date)','execute'),'POS batch readers remain server-only');
select set_eq(
 $$select value from jsonb_array_elements(office_inventory_purchase_orders_batch(array[md5('store-0')::uuid,md5('store-1')::uuid],null)->'rows')$$,
 $$select to_jsonb(t) from (select * from office_get_inventory_purchase_orders(null,md5('store-0')::uuid,null) union all select * from office_get_inventory_purchase_orders(null,md5('store-1')::uuid,null)) t$$,
 'purchase summary keeps all original fields across requested stores');
select is(jsonb_array_length(office_inventory_purchase_orders_batch(array[md5('store-0')::uuid,md5('store-1')::uuid,md5('store-2')::uuid],null)->'rows'),1500,'all purchases beyond REST row cap survive');
select is(jsonb_array_length(office_inventory_purchase_orders_batch(array[md5('store-0')::uuid], 'received')->'rows'),250,'status filter remains scoped');
select is(office_inventory_purchase_orders_batch(array[]::uuid[],null),'{"rows":[]}'::jsonb,'empty store list returns no purchases');
select throws_like($$select office_inventory_purchase_orders_batch(array_fill(md5('store-0')::uuid,array[101]),null)$$,'%PURCHASE_BATCH_SCOPE_INVALID%','oversized purchase scope rejected');
select ok(not has_function_privilege('authenticated','office_inventory_purchase_orders_batch(uuid[],text)','execute') and not has_function_privilege('anon','office_inventory_purchase_orders_batch(uuid[],text)','execute'),'purchase summary is server-only');
select is(jsonb_array_length(office_inventory_purchase_handoff_batch(
  array[md5('store-1')::uuid,md5('store-2')::uuid],
  array[md5('purchase-2')::uuid,md5('purchase-1')::uuid], 'office-actor')->'rows'),
  2, 'handoff batch returns each requested order');
select is((office_inventory_purchase_handoff_batch(
  array[md5('store-1')::uuid,md5('store-2')::uuid],
  array[md5('purchase-2')::uuid,md5('purchase-1')::uuid], 'office-actor')->'rows'->0->>'order_id'),
  md5('purchase-2')::uuid::text, 'handoff batch preserves input order');
select is((office_inventory_purchase_handoff_batch(
  array[md5('store-1')::uuid],array[md5('purchase-1')::uuid], 'office-actor')->'rows'->0->'detail'),
  office_get_inventory_purchase_order_detail(md5('purchase-1')::uuid),
  'handoff detail matches original POS contract');
select is((office_inventory_purchase_handoff_batch(
  array[md5('store-1')::uuid],array[md5('purchase-1')::uuid], 'office-actor')->'rows'->0->'snapshot'),
  procurement_order_snapshot(md5('store-1')::uuid,md5('purchase-1')::uuid,
    jsonb_build_object('system','office','subject_id','office-actor','store_id',md5('store-1')::uuid,'can_view_prices',true)),
  'handoff snapshot preserves confirmed receipt and return values');
select throws_like($$select office_inventory_purchase_handoff_batch(
  array[md5('store-0')::uuid],array[md5('purchase-1')::uuid], 'office-actor')$$,
  '%PURCHASE_HANDOFF_SCOPE_FORBIDDEN%', 'handoff rejects an order outside supplied store scope');
select throws_like($$select office_inventory_purchase_handoff_batch(
  array[md5('store-1')::uuid],array_fill(md5('purchase-1')::uuid,array[51]), 'office-actor')$$,
  '%PURCHASE_HANDOFF_SCOPE_INVALID%', 'handoff rejects more than 50 order IDs');
select ok(not has_function_privilege('authenticated','office_inventory_purchase_handoff_batch(uuid[],uuid[],text)','execute')
  and not has_function_privilege('anon','office_inventory_purchase_handoff_batch(uuid[],uuid[],text)','execute'),
  'handoff evidence stays server-only');
select * from finish();
rollback;
