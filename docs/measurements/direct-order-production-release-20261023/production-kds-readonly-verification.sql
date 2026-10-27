BEGIN READ ONLY;
SET LOCAL statement_timeout='5s';
WITH target AS MATERIALIZED (
 SELECT q.request_id,f.order_id,e.id AS queue_id
 FROM public.direct_order_customer_requirements q
 JOIN public.direct_order_financials f ON f.request_id=q.request_id
 JOIN public.emergency_order_queue e ON e.order_id=f.order_id
 WHERE q.source_kind='order' AND q.print_scope='cashier' AND q.status='confirmed'
 AND q.restaurant_id=(SELECT restaurant_id FROM public.direct_order_storefronts WHERE public_slug='bunsikclub-binh-thanh')
 ORDER BY q.created_at DESC,q.id DESC LIMIT 1
), expected AS MATERIALIZED (
 SELECT t.request_id,string_agg(COALESCE(q.item_label_vi||': ','')||q.print_reply_vi,E'\n' ORDER BY q.created_at,q.id) AS notes
 FROM target t LEFT JOIN public.direct_order_customer_requirements q ON q.request_id=t.request_id AND q.status='confirmed' AND q.print_scope IN('preparation','both')
 GROUP BY t.request_id
), screen AS MATERIALIZED (
 SELECT page FROM target t CROSS JOIN LATERAL jsonb_array_elements(public.emergency_enrich_start_ready_orders(
 jsonb_build_array(jsonb_build_object('queue_id',t.queue_id,'order_id',t.order_id,'station','kitchen','items','[]'::jsonb),
 jsonb_build_object('queue_id',t.queue_id,'order_id',t.order_id,'station','tray','items','[]'::jsonb)))) page
)
SELECT (SELECT count(*) FROM target) AS existing_private_orders_checked,
 count(*) AS station_rows_checked,
 bool_and((page->'direct_order_packing'->>'confirmed_notes') IS NOT DISTINCT FROM expected.notes) AS kitchen_checker_show_preparation_scope_only
FROM screen CROSS JOIN expected;
COMMIT;
