SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
-- Cover the shared-aggregate summary overload without relying on an unrelated
-- production migration. Existing overloads in a developer checkout are kept.
DO $$ DECLARE d text; BEGIN
 IF to_regprocedure('public.get_pos_daily_sales_summary(date,boolean)') IS NOT NULL THEN RETURN; END IF;
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 d:=replace(d,'get_pos_daily_sales_summary(p_business_date date)',
  'get_pos_daily_sales_summary(p_business_date date,p_include_export_metadata boolean)');
 d:=replace(d,'sum(item.vat_amount) vat FROM paid p',
  'sum(item.vat_amount) vat,count(*) source_item_count,sum(CASE WHEN item.vat_rate=-1 THEN jsonb_array_length(item.vat_breakdown) ELSE 1 END) export_line_count FROM paid p');
 d:=replace(d,'(SELECT count(*) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false)',
  'COALESCE(tax.source_item_count,0)');
 d:=replace(d,'(SELECT COALESCE(sum(CASE WHEN item.vat_rate=-1 THEN jsonb_array_length(item.vat_breakdown) ELSE 1 END),0) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false)',
  'COALESCE(tax.export_line_count,0)');
 EXECUTE d;
END $$;
CREATE TABLE no_delivery_fee_scope(order_id uuid,menu_id uuid,old_lines jsonb,source_item_count integer,export_line_count integer);
DO $$ DECLARE o uuid:=gen_random_uuid();m uuid:=gen_random_uuid();batch jsonb;a jsonb;b jsonb;BEGIN
 INSERT INTO public.menu_items(id,restaurant_id,name,vat_rate)
 VALUES(m,'20000000-0000-0000-0000-000000000001','Approved food',8);
 batch:=jsonb_build_array(jsonb_build_object('approval_type','menu_item','menu_item_id',m,
  'invoice_name_vi','Japchae (Miến Xào)','unit_name','Phần','mapping_version','fixture-permanent-v1',
  'source_reference','isolated owner approval','effective_from','2026-10-12T00:00:00+07:00','effective_to',NULL));
 a:=public.approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',batch);
 b:=public.approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',batch);
 PERFORM fixture_assert(a=b AND (SELECT count(*)=1 FROM public.menu_invoice_profiles WHERE menu_item_id=m),'permanent approval retry preserves its real ID');
 INSERT INTO public.orders(id,status,sales_channel) VALUES(o,'completed','delivery');
 INSERT INTO public.payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
 VALUES(o,'20000000-0000-0000-0000-000000000001','2026-10-12 12:00+07',10800,10800,'BANKTRANSFER',true);
 INSERT INTO public.order_items(id,order_id,menu_item_id,display_name,label,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
 VALUES(gen_random_uuid(),o,m,'Food','Food',2,5000,10000,8,800,10800,'2026-10-12 12:00+07','served','menu_item'),
 (gen_random_uuid(),o,NULL,'Phí giao hàng','Phí giao hàng',1,0,0,0,0,0,'2026-10-12 12:00:01+07','served','service_charge');
 INSERT INTO public.meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
 VALUES(gen_random_uuid(),o,'restaurant_pos',now(),'10000000-0000-0000-0000-000000000001','CK','[{"display_name":"Legacy fee placeholder"}]','[]',2);
 INSERT INTO no_delivery_fee_scope SELECT o,m,line_items_snapshot FROM public.meinvoice_jobs WHERE order_id=o;
 PERFORM fixture_assert((SELECT jsonb_array_length(line_items)=2 FROM public.pos_restaurant_receipt_rows_fresh('2026-10-12',ARRAY[o])),'legacy zero fee is reproduced before correction');
 UPDATE no_delivery_fee_scope SET source_item_count=(e->>'source_item_count')::integer,export_line_count=(e->>'export_line_count')::integer
 FROM jsonb_array_elements(public.get_pos_daily_sales_summary('2026-10-12')->'entities') e
 WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001';
END $$;
