DO $$
DECLARE
  c record; old_row jsonb; new_row jsonb; actual jsonb; expected_delivery jsonb;
  store uuid := 'd2000000-0000-4000-8000-000000000001';
BEGIN
  FOR c IN SELECT * FROM fallback_read_test.cases LOOP
    actual := public.direct_delivery_ticket_list_v3(store, c.statuses, c.row_limit);
    PERFORM fallback_read_test.assert(jsonb_array_length(actual) = jsonb_array_length(c.expected),
      'READ_ROW_COUNT_CHANGED:' || c.name);
    FOR old_row, new_row IN
      SELECT old.value, new.value
      FROM jsonb_array_elements(c.expected) WITH ORDINALITY old(value, n)
      JOIN jsonb_array_elements(actual) WITH ORDINALITY new(value, n) USING(n)
    LOOP
      PERFORM fallback_read_test.assert(old_row - 'delivery' = new_row - 'delivery',
        'READ_TICKET_ITEMS_OR_ORDER_CHANGED:' || c.name);
      expected_delivery := jsonb_build_object(
        'diner_count', old_row->'delivery'->'diner_count',
        'method', old_row->'delivery'->'method',
        'version', old_row->'delivery'->'version');
      PERFORM fallback_read_test.assert(new_row->'delivery' = expected_delivery,
        'READ_PACKING_CHANGED_OR_FINANCIAL_CONTEXT_LEAKED:' || c.name);
    END LOOP;
  END LOOP;
  actual := public.direct_delivery_ticket_list_v3(store, NULL, 200);
  PERFORM fallback_read_test.assert(EXISTS(
    SELECT 1 FROM jsonb_array_elements(actual) row
    WHERE row->>'request_id' = md5('read-request-1')::uuid::text
      AND row->'items' = '[]'::jsonb AND row->'delivery'->'diner_count' = 'null'::jsonb),
    'LEGACY_NULL_COUNT_OR_EMPTY_ITEMS_LOST');
  PERFORM fallback_read_test.assert(NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(actual) row
    WHERE row->>'request_id' IN (md5('read-request-201')::uuid::text,
      md5('read-request-202')::uuid::text, md5('read-request-203')::uuid::text)),
    'OTHER_DAY_OR_STORE_LEAKED');
  PERFORM fallback_read_test.assert(public.direct_delivery_ticket_list_v3(store) =
    public.direct_delivery_ticket_list_v3(store, NULL, 100), 'DEFAULT_LIMIT_CHANGED');
  PERFORM fallback_read_test.expect_error(
    format('SELECT public.direct_delivery_ticket_list_v3(%L,NULL,0)', store), 'DIRECT_ORDER_LIMIT_INVALID');
  PERFORM fallback_read_test.expect_error(
    format('SELECT public.direct_delivery_ticket_list_v3(%L,NULL,201)', store), 'DIRECT_ORDER_LIMIT_INVALID');
  PERFORM fallback_read_test.expect_error(
    format('SELECT public.direct_delivery_ticket_list_v3(%L,NULL,NULL)', store), 'DIRECT_ORDER_LIMIT_INVALID');
  PERFORM fallback_read_test.expect_error(
    'SELECT public.direct_delivery_ticket_list_v3(''d2000000-0000-4000-8000-000000000002'')',
    'DIRECT_ORDER_FORBIDDEN');
  UPDATE public.users SET role = 'waiter' WHERE auth_id = auth.uid();
  PERFORM fallback_read_test.expect_error(
    format('SELECT public.direct_delivery_ticket_list_v3(%L)', store), 'DIRECT_ORDER_FORBIDDEN');
  UPDATE public.users SET role = 'kitchen' WHERE auth_id = auth.uid();
  PERFORM fallback_read_test.assert(jsonb_array_length(public.direct_delivery_ticket_list_v3(store)) = 100,
    'KITCHEN_ACCESS_LOST');
  PERFORM fallback_read_test.assert(
    NOT has_function_privilege('anon', 'public.direct_delivery_ticket_list_v3(uuid,text[],integer)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.direct_delivery_ticket_list_v3(uuid,text[],integer)', 'EXECUTE'),
    'READ_PRIVILEGE_CHANGED');
  UPDATE public.users SET role = 'cashier', restaurant_id = original.restaurant_id
  FROM fallback_read_test.original_actor original WHERE public.users.id = original.id;
END $$;
-- Separate PostgreSQL sessions flushed real function counters for every size.
SELECT fallback_read_test.assert(count(*) = 8 AND bool_and(
  rpc_calls = 1 AND actor_calls = 1 AND
  CASE WHEN phase = 'before' THEN helper_calls = row_limit AND legacy_calls = 1
       ELSE helper_calls = 0 AND legacy_calls = 0 END),
  'PER_TICKET_FUNCTION_CALL_REGRESSION') FROM fallback_read_test.measurements;
SELECT phase, row_limit, helper_calls, legacy_calls, actor_calls, rpc_calls
FROM fallback_read_test.measurements ORDER BY row_limit, phase;
\echo DIRECT_ORDER_SET_BASED_READ_PARITY_AND_CALLS=PASS
