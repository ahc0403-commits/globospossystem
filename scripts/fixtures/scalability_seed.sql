-- psql -v store_count=N -v history_days=D; disposable guarded DB only.
DO $$ BEGIN
  IF current_database()<>'payroll_test' THEN RAISE EXCEPTION 'TEST_DATABASE_REQUIRED'; END IF;
END $$;
TRUNCATE public.order_items,public.payments,public.orders,public.external_sales,
  public.photo_objet_sales,public.meinvoice_jobs,public.emergency_fulfillment_items;
INSERT INTO public.orders
SELECT md5('order-'||s||'-'||i)::uuid,('10000000-0000-0000-0000-'||lpad(s::text,12,'0'))::uuid,
  'completed',CASE WHEN i%5=0 THEN 'delivery' ELSE 'dine_in' END,
  '2026-09-05 02:00+00'::timestamptz-(i%:history_days)*interval '1 day'
FROM generate_series(1,:store_count) s CROSS JOIN generate_series(1,1000) i;
INSERT INTO public.payments
SELECT md5('payment-'||s||'-'||i)::uuid,('10000000-0000-0000-0000-'||lpad(s::text,12,'0'))::uuid,
  md5('order-'||s||'-'||i)::uuid,110000,100000,CASE WHEN i%2=0 THEN 'CASH' ELSE 'BANKTRANSFER' END,
  '2026-09-05 02:00+00'::timestamptz-(i%:history_days)*interval '1 day',false,NULL,true
FROM generate_series(1,:store_count) s CROSS JOIN generate_series(1,1000) i;
INSERT INTO public.order_items SELECT md5(id::text||'item')::uuid,id,'served' FROM public.orders;
INSERT INTO public.external_sales
SELECT md5('delivery-'||s||'-'||i)::uuid,('10000000-0000-0000-0000-'||lpad(s::text,12,'0'))::uuid,
  20000,'2026-09-05 02:00+00'::timestamptz-(i%30)*interval '1 day',true,'completed'
FROM generate_series(1,:store_count) s CROSS JOIN generate_series(1,100) i;
INSERT INTO public.photo_objet_sales
SELECT md5('photo-'||s||'-'||i)::uuid,('10000000-0000-0000-0000-'||lpad(s::text,12,'0'))::uuid,
  '2026-09-05'::date-i,50000,10000,2
FROM generate_series(1,:store_count) s CROSS JOIN generate_series(0,29) i;
INSERT INTO public.emergency_fulfillment_items
SELECT md5('item-'||s||'-'||q||'-'||i)::uuid,md5('session-'||s)::uuid,
  md5('order-'||s||'-'||q)::uuid,md5('queue-'||s||'-'||q)::uuid,
  md5('source-item-'||s||'-'||q||'-'||i)::uuid,'2026-09-05 02:00+00',false,2,0
FROM generate_series(1,:store_count) s CROSS JOIN generate_series(1,100) q CROSS JOIN generate_series(1,4) i;
ANALYZE public.orders;
ANALYZE public.payments;
ANALYZE public.order_items;
ANALYZE public.external_sales;
ANALYZE public.photo_objet_sales;
ANALYZE public.emergency_fulfillment_items;
