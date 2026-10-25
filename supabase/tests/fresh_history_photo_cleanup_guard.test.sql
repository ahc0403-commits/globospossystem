-- Run with guard_sql set to the exact first DO block of the historical cleanup.
-- This uses the real fully replayed schema. All synthetic rows roll back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,auth,pg_catalog;
select plan(9);
select lives_ok(:'guard_sql','fully absent historical tenant is a valid fresh installation');
insert into public.brands(id,brand_master_id,code,name,short_code)
values('77000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000012','qa_photo_guard','QA isolated historical guard','QAG');
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','brand presence cannot use the absent-tenant branch');
insert into public.tax_entity_brands(tax_entity_id,brand_id) values('00000000-0000-0000-0000-000000000011','77000000-0000-0000-0000-000000000001');
insert into public.restaurants(id,name,brand_id,tax_entity_id,short_code)
values('ed100000-0000-4000-8000-000000000001','QA isolated Photo guard','77000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000011','QAG');
insert into public.inventory_items(restaurant_id,name,unit,created_at)
select 'ed100000-0000-4000-8000-000000000001','QA guarded item '||n,'g','2026-05-06 09:00:57.334069+00' from generate_series(1,47)n;
insert into public.inventory_products(restaurant_id,brand_id,name,stock_unit,base_unit,base_unit_factor,created_at)
select 'ed100000-0000-4000-8000-000000000001','77000000-0000-0000-0000-000000000001','QA guarded product '||n,'g','g',1,'2026-05-06 09:06:00.256853+00' from generate_series(1,47)n;
insert into public.inventory_suppliers(brand_id,supplier_name,created_at)
select '77000000-0000-0000-0000-000000000001','QA guarded supplier '||n,'2026-05-06 09:00:57.334069+00' from generate_series(1,2)n;
insert into public.inventory_stock_audit_sessions(restaurant_id,audit_no,created_at)
select 'ed100000-0000-4000-8000-000000000001','QA-GUARD-'||n,'2026-05-06 09:00:57.334069+00' from generate_series(1,5)n;
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','partial historical inventories remain rejected');
insert into public.inventory_items(restaurant_id,name,unit,created_at)
values('ed100000-0000-4000-8000-000000000001','QA guarded item 48','g','2026-05-06 09:00:57.334069+00');
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','correct item count does not excuse missing products');
insert into public.inventory_products(restaurant_id,brand_id,name,stock_unit,base_unit,base_unit_factor,created_at)
values('ed100000-0000-4000-8000-000000000001','77000000-0000-0000-0000-000000000001','QA guarded product 48','g','g',1,'2026-05-06 09:06:00.256853+00');
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','correct item/product counts do not excuse missing suppliers');
insert into public.inventory_suppliers(brand_id,supplier_name,created_at)
values('77000000-0000-0000-0000-000000000001','QA guarded supplier 3','2026-05-06 09:00:57.334069+00');
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','correct item/product/supplier counts do not excuse missing audit sessions');
insert into public.inventory_stock_audit_sessions(restaurant_id,audit_no,created_at)
values('ed100000-0000-4000-8000-000000000001','QA-GUARD-6','2026-05-06 09:00:57.334069+00');
select lives_ok(:'guard_sql','original exact 48/48/3/6 installation remains accepted');
insert into public.inventory_items(restaurant_id,name,unit,created_at)
values('ed100000-0000-4000-8000-000000000001','QA guarded unexpected item','g','2026-05-06 09:00:57.334069+00');
select throws_like(:'guard_sql','%PHOTO_OPS_INVENTORY_SEED_MISMATCH%','an unexpected additional historical item still fails closed');
select is((select count(*) from public.inventory_products where restaurant_id='ed100000-0000-4000-8000-000000000001'),48::bigint,'guard checks do not delete any fixture record');
select * from finish();
rollback;
