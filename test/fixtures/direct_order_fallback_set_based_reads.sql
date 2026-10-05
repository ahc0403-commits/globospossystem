-- Synthetic data only; run before replacing v3 in the disposable SQL runner.
DO $$ BEGIN
  IF current_database() <> 'codex_direct_photo' THEN
    RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED';
  END IF;
END $$;
CREATE SCHEMA fallback_read_test;
CREATE FUNCTION fallback_read_test.assert(p_ok boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%', p_message; END IF;
END $$;
CREATE FUNCTION fallback_read_test.expect_error(p_sql text, p_error text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN actual := SQLERRM; END;
  PERFORM fallback_read_test.assert(actual = p_error,
    format('EXPECTED %s, GOT %s', p_error, actual));
END $$;

-- Use the existing production indexes, not fixture-only optimization indexes.
CREATE INDEX IF NOT EXISTS direct_delivery_tickets_store_status_created
  ON public.direct_delivery_fulfillment_tickets(restaurant_id, status, created_at, id);
CREATE INDEX IF NOT EXISTS direct_delivery_ticket_items_ticket
  ON public.direct_delivery_fulfillment_ticket_items(ticket_id, sort_order, id);
CREATE INDEX IF NOT EXISTS direct_delivery_ticket_items_store
  ON public.direct_delivery_fulfillment_ticket_items(restaurant_id, ticket_id);

INSERT INTO public.restaurants(id, name) VALUES
  ('d2000000-0000-4000-8000-000000000001', 'Read test store'),
  ('d2000000-0000-4000-8000-000000000002', 'Other read test store');
CREATE TABLE fallback_read_test.original_actor AS
  SELECT id, restaurant_id FROM public.users WHERE auth_id = auth.uid();
UPDATE public.users SET restaurant_id = 'd2000000-0000-4000-8000-000000000001'
  WHERE auth_id = auth.uid();
INSERT INTO public.direct_order_sessions(id, restaurant_id, secret_hash, locale)
SELECT store.id, store.id, repeat(md5(store.id::text), 2), 'en'
FROM public.restaurants store
WHERE store.id IN ('d2000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000002');

CREATE TABLE fallback_read_test.tickets AS
SELECT n, md5('read-request-' || n)::uuid AS request_id,
       md5('read-ticket-' || n)::uuid AS ticket_id,
       CASE WHEN n = 203 THEN 'd2000000-0000-4000-8000-000000000002'::uuid
         ELSE 'd2000000-0000-4000-8000-000000000001'::uuid END AS store_id,
       ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
          AT TIME ZONE 'Asia/Ho_Chi_Minh') + interval '12 hours'
         + CASE WHEN n = 201 THEN interval '-1 day'
                WHEN n = 202 THEN interval '1 day' ELSE interval '0' END AS created_at
FROM generate_series(1, 203) n;

INSERT INTO public.direct_order_requests(id, restaurant_id, session_id,
  client_request_id, reference_code, state, locale, diner_count,
  fulfillment_method, fulfillment_version)
SELECT request_id, store_id, store_id, request_id, 'D' || lpad(n::text, 8, '0'),
       'approved', 'en', CASE WHEN n = 1 THEN NULL ELSE 1 + n % 100 END,
       CASE WHEN n % 2 = 0 THEN 'pickup' ELSE 'delivery' END, 1 + n % 3
FROM fallback_read_test.tickets;
INSERT INTO public.direct_delivery_fulfillment_tickets(id, request_id,
  restaurant_id, status, pickup_code, version, created_at)
SELECT ticket_id, request_id, store_id,
       CASE WHEN n % 2 = 0 THEN 'ready' ELSE 'pending' END,
       'D' || lpad(n::text, 8, '0'), 1 + n % 3, created_at
FROM fallback_read_test.tickets;
INSERT INTO public.direct_delivery_fulfillment_ticket_items(id, ticket_id,
  restaurant_id, menu_item_id, display_name_ko, display_name_vi, display_name_en,
  quantity, item_note, sort_order)
SELECT md5('read-item-' || ticket.n || '-' || item.n)::uuid, ticket.ticket_id,
       ticket.store_id, 'd1000000-0000-4000-8000-000000000003',
       '항목 ' || item.n, 'Món ' || item.n, 'Item ' || item.n, item.n,
       CASE WHEN item.n = 1 THEN NULL ELSE 'Packing note' END,
       CASE WHEN item.n = 1 THEN 2 ELSE 1 END
FROM fallback_read_test.tickets ticket
CROSS JOIN generate_series(1, 3) item(n)
WHERE ticket.n <> 1;
ANALYZE public.direct_order_requests;
ANALYZE public.direct_delivery_fulfillment_tickets;
ANALYZE public.direct_delivery_fulfillment_ticket_items;

CREATE TABLE fallback_read_test.cases(
  name text PRIMARY KEY, statuses text[], row_limit integer, expected jsonb
);
INSERT INTO fallback_read_test.cases(name, statuses, row_limit) VALUES
  ('one', NULL, 1), ('fifty', NULL, 50), ('hundred', NULL, 100),
  ('two_hundred', NULL, 200), ('pending', ARRAY['pending'], 200),
  ('ready', ARRAY['ready'], 200), ('multi_status', ARRAY['pending', 'ready'], 100),
  ('no_match', ARRAY['completed'], 200), ('empty_status', ARRAY[]::text[], 200);
UPDATE fallback_read_test.cases SET expected = public.direct_delivery_ticket_list_v3(
  'd2000000-0000-4000-8000-000000000001', statuses, row_limit);
SELECT fallback_read_test.assert(jsonb_array_length(expected) = 200,
  'PREDECESSOR_BUSINESS_DAY_OR_STORE_SCOPE_WRONG')
FROM fallback_read_test.cases WHERE name = 'two_hundred';
CREATE TABLE fallback_read_test.measurements(
  phase text, row_limit integer, helper_calls bigint, legacy_calls bigint,
  actor_calls bigint, rpc_calls bigint, PRIMARY KEY(phase, row_limit)
);
