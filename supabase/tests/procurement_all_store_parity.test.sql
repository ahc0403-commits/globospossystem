BEGIN;
DO $$
DECLARE before public.test_procurement_parity_before%rowtype;
  page jsonb; request jsonb; actor integer; store_number integer;
BEGIN
  SELECT * INTO STRICT before FROM public.test_procurement_parity_before;
  ASSERT before.users = (SELECT jsonb_agg(to_jsonb(u) ORDER BY id) FROM public.users u), 'Account identities and roles are unchanged';
  ASSERT before.stores = (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.restaurants r), 'Store IDs and activation are unchanged';
  ASSERT before.requests = (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.inventory_purchase_requests r), 'Historical PRs are unchanged';
  ASSERT before.orders = (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.inventory_purchase_orders p), 'Historical POs are unchanged';
  ASSERT before.requirements = (SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.store_fixed_account_requirements q), 'Fixed account mappings are unchanged';
  ASSERT before.reference = (SELECT to_jsonb(p) FROM public.procurement_store_policies p WHERE restaurant_id = test_uuid(101)), 'Reference row version remains unchanged';
  ASSERT before.target_version + 1 = (SELECT row_version FROM public.procurement_store_policies WHERE restaurant_id = test_uuid(102));
  ASSERT (SELECT row_version = 1 FROM public.procurement_store_policies WHERE restaurant_id = test_uuid(103));
  ASSERT NOT EXISTS (SELECT 1 FROM public.procurement_store_policies WHERE restaurant_id IN (test_uuid(18100), test_uuid(18101), test_uuid(18102))), 'Inactive and non-ordering stores are excluded';
  ASSERT (SELECT count(*) = 2 FROM public.procurement_events WHERE action = 'align_procurement_policy'), 'One event per changed store, never one per account';
  ASSERT EXISTS (SELECT 1 FROM public.procurement_events WHERE action = 'align_procurement_policy' AND restaurant_id = test_uuid(102) AND previous_state->>'enabled' = 'false' AND next_state->>'enabled' = 'true');
  ASSERT EXISTS (SELECT 1 FROM public.procurement_events WHERE action = 'align_procurement_policy' AND restaurant_id = test_uuid(103) AND previous_state IS NULL);

  -- Exercise the real paged API under each existing requester/SM/BM identity.
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  FOREACH actor IN ARRAY ARRAY[1, 2, 3, 5, 6, 7, 9] LOOP
    store_number := CASE WHEN actor <= 3 THEN 101 WHEN actor <= 7 THEN 102 ELSE 103 END;
    PERFORM set_config('request.jwt.claim.sub', test_uuid(actor)::text, true);
    page := public.procurement_workspace_page(test_uuid(store_number), '{"request_view":true,"request_sort":"created"}');
    ASSERT page->>'enabled' = 'true';
    ASSERT page->'policy'->>'two_stage_required' = 'true';
    ASSERT page->'actor'->>'can_create' = 'true';
    ASSERT (page->>'store_id')::uuid = test_uuid(store_number);
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub', test_uuid(5)::text, true);
  request := public.procurement_command(test_uuid(102), 'create_request', NULL, 0, 'parity-create',
    jsonb_build_object('reason', 'Parity verification', 'requested_delivery_date', current_date + 1,
      'lines', jsonb_build_array(jsonb_build_object('product_id', test_uuid(302), 'quantity', 1, 'unit', 'g'))));
  ASSERT request->>'approval_policy_version' = '3', 'New JeonGabok PRs use the same requester -> SM -> buyer policy';
  PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L)', test_uuid(101)), 'PROCUREMENT_SCOPE_FORBIDDEN');
  PERFORM public.test_expect_error(format('SELECT public.create_manual_inventory_purchase_order(%L,%L,%L::jsonb,current_date,NULL)',
    test_uuid(102), test_uuid(201), '[{"supplier_item_id":"00000000-0000-4000-8000-000000000402","quantity":1}]'), 'PROCUREMENT_REQUEST_REQUIRED');
  RAISE NOTICE 'PASS: all-store policy parity, audit, role-scoped API, policy-3 PR creation, legacy-creation guard and unchanged history';
END $$;
ROLLBACK;
