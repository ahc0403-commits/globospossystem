GRANT ALL ON public.external_sales, public.delivery_settlements,
  public.delivery_settlement_items TO anon, authenticated, service_role;

INSERT INTO public.external_sales(
  id,restaurant_id,source_system,external_order_id,gross_amount,net_amount,order_status
) VALUES('a3000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001','deliberry','historical-sale',100000,95000,'completed');
INSERT INTO public.delivery_settlements(
  id,restaurant_id,source_system,period_start,period_end,period_label,gross_total,net_settlement,status
) VALUES('a4000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001','deliberry','2026-09-01','2026-09-15','2026-09-A',100000,95000,'calculated');
INSERT INTO public.delivery_settlement_items(settlement_id,item_type,amount)
VALUES('a4000000-0000-4000-8000-000000000001','platform_commission',5000);
INSERT INTO public.deliberry_operational_orders(
  id,restaurant_id,external_order_id,trace_id,status
) VALUES('a5000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001','historical-order','historical-trace','accepted');
INSERT INTO public.deliberry_operational_order_events(
  operational_order_id,restaurant_id,source_system,destination_system,event_id,
  trace_id,event_type,external_order_id
) VALUES('a5000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001','pos','deliberry','historical-event',
  'historical-trace','DELIBERRY_ORDER_ACCEPTED','historical-order');

CREATE TABLE retirement_history_before AS
SELECT 'external_sales' AS table_name,jsonb_agg(to_jsonb(t) ORDER BY id) AS rows FROM public.external_sales t
UNION ALL SELECT 'delivery_settlements',jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.delivery_settlements t
UNION ALL SELECT 'delivery_settlement_items',jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.delivery_settlement_items t
UNION ALL SELECT 'deliberry_operational_orders',jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.deliberry_operational_orders t
UNION ALL SELECT 'deliberry_operational_order_events',jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.deliberry_operational_order_events t;
