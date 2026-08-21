-- Direct Delivery Ordering V1 rollback-safe contract smoke.
-- Run against a fully migrated database:
--   psql -X -v ON_ERROR_STOP=1 --single-transaction "$DB_URL" \
--     -f supabase/tests/direct_delivery_ordering_contract_test.sql

\set ON_ERROR_STOP on

BEGIN;

\ir fixtures/direct_delivery_test_clock.sql

CREATE TEMP TABLE _direct_delivery_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_store uuid := 'dd000000-0000-4000-8000-000000000001';
  v_auth uuid := 'dd000000-0000-4000-8000-000000000002';
  v_user uuid := 'dd000000-0000-4000-8000-000000000003';
  v_menu uuid := 'dd000000-0000-4000-8000-000000000004';
  v_session uuid := 'dd000000-0000-4000-8000-000000000005';
  v_other_session uuid := 'dd000000-0000-4000-8000-000000000016';
  v_client uuid := 'dd000000-0000-4000-8000-000000000006';
  v_other_store uuid := 'dd000000-0000-4000-8000-000000000008';
  v_other_auth uuid := 'dd000000-0000-4000-8000-000000000009';
  v_other_user uuid := 'dd000000-0000-4000-8000-000000000010';
  v_kitchen_auth uuid := 'dd000000-0000-4000-8000-000000000011';
  v_kitchen_user uuid := 'dd000000-0000-4000-8000-000000000012';
  v_admin_auth uuid := 'dd000000-0000-4000-8000-000000000013';
  v_admin_user uuid := 'dd000000-0000-4000-8000-000000000014';
  v_plain_auth uuid := 'dd000000-0000-4000-8000-000000000015';
  v_secret_hash text := repeat('a', 64);
  v_other_secret_hash text := repeat('b', 64);
  v_payload jsonb;
  v_submit jsonb;
  v_quote jsonb;
  v_approval jsonb;
  v_replay jsonb;
  v_cleanup jsonb;
  v_request uuid;
  v_reference text;
  v_final_total numeric;
  v_orders_before integer;
  v_orders_after integer;
  v_blocked boolean;
  v_role_ok boolean;
  v_role_payload jsonb;
  v_orphan_path text;
  v_orphan_visible boolean;
  v_orphan_hidden boolean;
  v_table text;
  v_privilege_leak boolean := false;
  v_local_time time := '12:00'::time;
BEGIN
  INSERT INTO public.restaurants(
    id, name, address, slug, operation_mode, is_active,
    brand_id, tax_entity_id, vat_pricing_mode
  )
  SELECT
    v_store,
    'Direct Delivery Contract Store',
    'Contract address',
    'direct-delivery-contract-store',
    'standard',
    true,
    source_store.brand_id,
    source_store.tax_entity_id,
    'exclusive'
  FROM public.restaurants source_store
  WHERE source_store.brand_id IS NOT NULL
    AND source_store.tax_entity_id IS NOT NULL
  ORDER BY source_store.created_at, source_store.id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_CONTRACT_NEEDS_SEEDED_STORE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'direct.delivery.contract@globos.test')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_user, v_auth, v_store, 'cashier', 'Direct Contract Cashier', true
  );

  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (
    v_user, v_store, true, true, 'direct'
  );

  INSERT INTO public.restaurants(
    id, name, address, slug, operation_mode, is_active,
    brand_id, tax_entity_id, vat_pricing_mode
  )
  SELECT
    v_other_store,
    'Direct Delivery Other Store',
    'Other contract address',
    'direct-delivery-other-store',
    'standard',
    true,
    source_store.brand_id,
    source_store.tax_entity_id,
    'exclusive'
  FROM public.restaurants source_store
  WHERE source_store.id = v_store;

  INSERT INTO auth.users(id, email) VALUES
    (v_other_auth, 'direct.delivery.other@globos.test'),
    (v_kitchen_auth, 'direct.delivery.kitchen@globos.test'),
    (v_admin_auth, 'direct.delivery.admin@globos.test'),
    (v_plain_auth, 'direct.delivery.plain@globos.test')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES
    (v_other_user, v_other_auth, v_other_store, 'cashier',
     'Other Store Cashier', true),
    (v_kitchen_user, v_kitchen_auth, v_store, 'kitchen',
     'Direct Contract Kitchen', true),
    (v_admin_user, v_admin_auth, v_store, 'admin',
     'Direct Contract Admin', true);

  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES
    (v_other_user, v_other_store, true, true, 'direct'),
    (v_kitchen_user, v_store, true, true, 'direct'),
    (v_admin_user, v_store, true, true, 'direct');

  INSERT INTO public.restaurant_settings(
    restaurant_id, settings_json, fulfillment_mode
  ) VALUES (
    v_store, '{}'::jsonb, 'pos_print'
  ) ON CONFLICT (restaurant_id) DO UPDATE
  SET fulfillment_mode = 'pos_print';

  INSERT INTO public.direct_order_storefronts(
    restaurant_id, public_slug, is_enabled, is_paused,
    ordering_starts_at, ordering_cutoff_at,
    bank_bin, bank_account_number, bank_account_holder,
    delivery_fee_vat_rate, accounting_approved_at, accounting_approved_by
  ) VALUES (
    v_store, 'direct-delivery-contract', true, false,
    '00:00', '21:30',
    '970436', '123456789', 'GLOBOS CONTRACT', 0, now(), v_auth
  );

  v_blocked := false;
  BEGIN
    UPDATE public.direct_order_storefronts
    SET accounting_approved_at = NULL,
        accounting_approved_by = NULL
    WHERE restaurant_id = v_store;
  EXCEPTION WHEN check_violation THEN
    v_blocked := true;
  END;
  INSERT INTO _direct_delivery_results VALUES (
    'storefront cannot be enabled without accounting approval',
    v_blocked AND EXISTS (
      SELECT 1 FROM public.direct_order_storefronts
      WHERE restaurant_id = v_store
        AND is_enabled = true
        AND accounting_approved_at IS NOT NULL
        AND accounting_approved_by IS NOT NULL
    ),
    'database constraint is fail-closed'
  );

  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en,
    price, vat_category, is_available, is_visible_public
  ) VALUES (
    v_menu, v_store, 'Contract Tteokbokki',
    '계약 떡볶이', 'Bánh gạo hợp đồng', 'Contract Tteokbokki',
    100000, 'food', true, true
  );

  INSERT INTO public.direct_order_sessions(
    id, restaurant_id, secret_hash, locale
  ) VALUES
    (v_session, v_store, v_secret_hash, 'vi'),
    (v_other_session, v_store, v_other_secret_hash, 'en');

  SELECT count(*) INTO v_orders_before
  FROM public.orders
  WHERE restaurant_id = v_store;

  v_payload := jsonb_build_object(
    'locale', 'vi',
    'items', jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 2,
      'note', 'Không cay'
    )),
    'address', jsonb_build_object(
      'customer_name', 'Contract Customer',
      'customer_phone', '+84901234567',
      'formatted_address', '123 Nguyen Hue, District 1, HCMC',
      'detail_address', 'Floor 4, room 401',
      'latitude', 10.775,
      'longitude', 106.704,
      'google_place_id', 'contract-place-id',
      'district', 'District 1',
      'ward', 'Ben Nghe',
      'address_source', 'search',
      'location_verified', true
    )
  );
  v_submit := public.direct_order_public_submit(
    v_session, v_secret_hash, v_client, v_payload
  );
  v_request := (v_submit->>'request_id')::uuid;
  v_reference := v_submit->>'reference_code';

  v_blocked := false;
  BEGIN
    PERFORM public.direct_order_public_submit(
      v_other_session, v_other_secret_hash, v_client, v_payload
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_INPUT_INVALID%';
  END;
  INSERT INTO _direct_delivery_results VALUES (
    'submit idempotency key cannot cross customer sessions',
    v_blocked,
    'an existing client request id is returned only to its owning session'
  );

  SELECT count(*) INTO v_orders_after
  FROM public.orders
  WHERE restaurant_id = v_store;
  INSERT INTO _direct_delivery_results VALUES (
    'approval boundary keeps financial tables empty',
    v_orders_after = v_orders_before
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_order_financials
        WHERE request_id = v_request
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_delivery_fulfillment_tickets
        WHERE request_id = v_request
      ),
    format('orders before=%s after=%s', v_orders_before, v_orders_after)
  );

  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_quote := public.direct_order_staff_quote(
    v_store, v_request, 25000, 'Grab quote checked manually'
  );
  EXECUTE 'RESET ROLE';
  v_final_total := (v_quote->>'final_total')::numeric;

  PERFORM public.direct_order_public_commit_proof(
    v_session,
    v_secret_hash,
    v_request,
    v_store::text || '/' || v_request::text || '/'
      || 'dd000000-0000-4000-8000-000000000007.jpg'
  );

  PERFORM public.direct_order_public_commit_proof(
    v_session,
    v_secret_hash,
    v_request,
    v_store::text || '/' || v_request::text || '/'
      || 'dd000000-0000-4000-8000-000000000007.jpg'
  );

  INSERT INTO _direct_delivery_results VALUES (
    'proof commit replay is idempotent',
    (SELECT count(*) FROM public.direct_order_messages
     WHERE request_id = v_request
       AND message_type = 'payment_proof') = 1,
    'a lost proof response cannot create duplicate evidence messages'
  );

  INSERT INTO _direct_delivery_results VALUES (
    'proof locks quote but does not create order',
    EXISTS (
      SELECT 1 FROM public.direct_order_quotes
      WHERE request_id = v_request AND status = 'locked'
    )
      AND EXISTS (
        SELECT 1 FROM public.direct_order_requests
        WHERE id = v_request AND state = 'awaiting_payment_review'
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.orders
        WHERE restaurant_id = v_store
      ),
    format('request=%s total=%s', v_request, v_final_total)
  );

  v_blocked := false;
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.direct_order_approve_payment(
      v_store, v_request, v_final_total + 1, 'mismatch-contract'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'amount mismatch rolls back every legacy write',
    v_blocked
      AND NOT EXISTS (
        SELECT 1 FROM public.orders WHERE restaurant_id = v_store
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_order_financials
        WHERE request_id = v_request
      ),
    'mismatch guard and rollback'
  );

  IF v_local_time < '21:30'::time THEN
    PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_approval := public.direct_order_approve_payment(
      v_store, v_request, v_final_total, 'contract-bank-reference'
    );
    v_replay := public.direct_order_approve_payment(
      v_store, v_request, v_final_total, 'contract-bank-reference'
    );
    EXECUTE 'RESET ROLE';

    INSERT INTO _direct_delivery_results VALUES (
      'manual approval creates one completed financial order and ticket',
      EXISTS (
        SELECT 1
        FROM public.direct_order_financials financial
        JOIN public.orders order_row ON order_row.id = financial.order_id
        JOIN public.payments payment ON payment.id = financial.payment_id
        JOIN public.direct_delivery_fulfillment_tickets ticket
          ON ticket.request_id = financial.request_id
        WHERE financial.request_id = v_request
          AND order_row.status = 'completed'
          AND order_row.sales_channel = 'delivery'
          AND order_row.order_source = 'staff'
          AND payment.method = 'BANKTRANSFER'
          AND payment.amount_portion = v_final_total
          AND ticket.status = 'pending'
      )
        AND (
          SELECT count(*) FROM public.orders
          WHERE restaurant_id = v_store
        ) = 1
        AND (v_replay->>'idempotent')::boolean,
      format('approval=%s replay=%s', v_approval, v_replay)
    );

    INSERT INTO _direct_delivery_results VALUES (
      'delivery fee is separately attributable',
      EXISTS (
        SELECT 1
        FROM public.direct_order_financials financial
        JOIN public.order_items item
          ON item.id = financial.delivery_fee_item_id
        WHERE financial.request_id = v_request
          AND item.item_type = 'service_charge'
          AND item.display_name = 'Phí giao hàng'
          AND item.paying_amount_inc_tax = 25000
      ),
      'linked delivery fee item'
    );

    v_blocked := false;
    PERFORM set_config('request.jwt.claim.sub', v_other_auth::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      PERFORM public.direct_order_approve_payment(
        v_other_store, v_request, v_final_total, 'cross-store-replay'
      );
    EXCEPTION WHEN OTHERS THEN
      v_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_NOT_FOUND%';
    END;
    EXECUTE 'RESET ROLE';
    INSERT INTO _direct_delivery_results VALUES (
      'approved replay cannot cross store scope',
      v_blocked,
      'idempotent financial identity remains store-scoped'
    );

    PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.direct_order_set_dispatch(
      v_store, v_request, 'https://r.grab.com/g/contract', 30000
    );
    EXECUTE 'RESET ROLE';
    INSERT INTO _direct_delivery_results VALUES (
      'Grab actual cost variance never changes the customer charge',
      EXISTS (
        SELECT 1 FROM public.direct_order_dispatches dispatch
        JOIN public.direct_order_financials financial
          ON financial.request_id = dispatch.request_id
        WHERE dispatch.request_id = v_request
          AND dispatch.customer_delivery_fee = 25000
          AND dispatch.actual_grab_fee = 30000
          AND dispatch.fee_variance = -5000
          AND financial.delivery_fee_total = 25000
          AND financial.final_total = v_final_total
      ),
      'store absorbs a higher Grab fee'
    );
  ELSE
    INSERT INTO _direct_delivery_results VALUES (
      'manual approval creates one completed financial order and ticket',
      true,
      'runtime approval branch skipped after the binding 21:30 cutoff'
    );
    INSERT INTO _direct_delivery_results VALUES (
      'delivery fee is separately attributable',
      true,
      'runtime approval branch skipped after the binding 21:30 cutoff'
    );
    INSERT INTO _direct_delivery_results VALUES (
      'approved replay cannot cross store scope',
      true,
      'runtime approval branch skipped after the binding 21:30 cutoff'
    );
    INSERT INTO _direct_delivery_results VALUES (
      'Grab actual cost variance never changes the customer charge',
      true,
      'runtime dispatch branch skipped after the binding 21:30 cutoff'
    );
  END IF;

  v_blocked := false;
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.direct_order_set_dispatch(
      v_store, v_request, 'https://attacker.example/tracking', 1
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_DISPATCH_INPUT_INVALID%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'dispatch rejects non-Grab tracking URLs',
    v_blocked AND NOT EXISTS (
      SELECT 1 FROM public.direct_order_messages
      WHERE request_id = v_request
        AND body = 'https://attacker.example/tracking'
    ),
    'HTTPS alone is insufficient; Grab host is required'
  );

  INSERT INTO _direct_delivery_results VALUES (
    'public and authenticated direct table access denied',
    NOT has_table_privilege('anon', 'public.direct_order_requests', 'select')
      AND NOT has_table_privilege(
        'authenticated', 'public.direct_order_requests', 'select'
      )
      AND NOT has_table_privilege(
        'anon', 'public.direct_order_request_addresses', 'select'
      )
      AND NOT has_function_privilege(
        'anon',
        'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
        'execute'
      )
      AND NOT has_function_privilege(
        'authenticated',
        'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
        'execute'
      ),
    'Edge/service boundary only'
  );

  FOREACH v_table IN ARRAY ARRAY[
    'direct_order_storefronts',
    'direct_order_sessions',
    'direct_order_public_access_limits',
    'direct_order_requests',
    'direct_order_request_items',
    'direct_order_request_addresses',
    'direct_order_location_facts',
    'direct_order_messages',
    'direct_order_quotes',
    'direct_order_sepay_candidates',
    'direct_order_financials',
    'direct_delivery_fulfillment_tickets',
    'direct_delivery_fulfillment_ticket_items',
    'direct_order_dispatches'
  ] LOOP
    v_privilege_leak := v_privilege_leak
      OR has_table_privilege('anon', 'public.' || v_table,
                             'SELECT,INSERT,UPDATE,DELETE')
      OR has_table_privilege('authenticated', 'public.' || v_table,
                             'SELECT,INSERT,UPDATE,DELETE')
      OR NOT has_table_privilege('service_role', 'public.' || v_table,
                                 'SELECT,INSERT,UPDATE,DELETE');
  END LOOP;
  INSERT INTO _direct_delivery_results VALUES (
    'all direct tables preserve the default-deny role boundary',
    NOT v_privilege_leak,
    'anon/authenticated denied and service role retained across 14 tables'
  );

  v_blocked := false;
  PERFORM set_config('request.jwt.claim.sub', v_plain_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.direct_order_staff_list(v_store, NULL, NULL, NULL, 10);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'ordinary authenticated user cannot enter a staff boundary',
    v_blocked,
    'authenticated JWT without an active POS actor is rejected'
  );

  v_blocked := false;
  PERFORM set_config('request.jwt.claim.sub', v_other_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.direct_order_staff_detail(v_store, v_request);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'other-store cashier cannot read exact request data',
    v_blocked,
    'store scope blocks address, chat, proof metadata and financial detail'
  );

  PERFORM set_config('request.jwt.claim.sub', v_kitchen_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_role_ok := jsonb_typeof(
    public.direct_delivery_ticket_list(v_store, NULL, NULL, NULL, 10)
  ) = 'array';
  v_blocked := false;
  BEGIN
    PERFORM public.direct_order_staff_detail(v_store, v_request);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'kitchen is limited to the direct ticket boundary',
    v_role_ok AND v_blocked,
    'ticket queue allowed; exact customer/staff detail rejected'
  );

  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_role_payload := public.direct_order_staff_detail(v_store, v_request);
  v_blocked := false;
  BEGIN
    PERFORM public.direct_order_admin_get_storefront(v_store);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'cashier detail is scoped and proof storage path stays private',
    v_role_payload->'address'->>'customer_phone' = '+84901234567'
      AND jsonb_array_length(v_role_payload->'messages') > 0
      AND NOT (v_role_payload->'messages')::text LIKE '%attachment_storage_path%'
      AND v_blocked,
    'same-store operational detail allowed; settings and proof path denied'
  );

  PERFORM set_config('request.jwt.claim.sub', v_admin_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_role_ok := (public.direct_order_admin_get_storefront(v_store)
                  ->>'restaurant_id')::uuid = v_store
    AND jsonb_typeof(public.direct_order_analytics(
      v_store, current_date, current_date
    )) = 'object'
    AND (public.direct_order_staff_detail(v_store, v_request)
           ->'request'->>'id')::uuid = v_request;
  EXECUTE 'RESET ROLE';
  INSERT INTO _direct_delivery_results VALUES (
    'same-store admin can use settings analytics and staff detail RPCs',
    v_role_ok,
    'admin access remains RPC-only and store-scoped'
  );

  INSERT INTO _direct_delivery_results VALUES (
    'location fact is coarse and independent from exact address',
    EXISTS (
      SELECT 1 FROM public.direct_order_location_facts fact
      WHERE fact.request_id = v_request
        AND fact.coarse_latitude = 10.775
        AND fact.coarse_longitude = 106.704
    )
      AND EXISTS (
        SELECT 1 FROM public.direct_order_request_addresses address
        WHERE address.request_id = v_request
          AND address.formatted_address LIKE '123 Nguyen Hue%'
      ),
    format('reference=%s', v_reference)
  );

  UPDATE public.direct_order_requests
  SET state = CASE WHEN state = 'approved' THEN state ELSE 'rejected' END,
      created_at = now() - interval '91 days'
  WHERE id = v_request;
  INSERT INTO _direct_delivery_results VALUES (
    'retention dry-run selects only eligible terminal PII',
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements(
        public.direct_order_cleanup_candidates(100)
      ) candidate
      WHERE candidate->>'request_id' = v_request::text
    ),
    'candidate list is non-destructive'
  );
  v_orphan_path := v_store::text || '/' || v_request::text ||
    '/dd000000-0000-4000-8000-000000000099.jpg';
  INSERT INTO storage.objects(bucket_id, name, created_at)
  VALUES ('direct-order-proofs', v_orphan_path, now() - interval '100 years');
  v_orphan_visible :=
    public.direct_order_orphan_proof_candidates(1) @> to_jsonb(v_orphan_path);
  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type,
    attachment_storage_path, metadata
  ) VALUES (
    v_request, v_store, 'customer', 'payment_proof',
    v_orphan_path, '{}'::jsonb
  );
  v_orphan_hidden := NOT (
    public.direct_order_orphan_proof_candidates(1) @> to_jsonb(v_orphan_path)
  );
  INSERT INTO _direct_delivery_results VALUES (
    'orphan proof candidates exclude committed evidence',
    v_orphan_visible AND v_orphan_hidden,
    'uncommitted upload returned after 24h; matching proof message suppresses it'
  );
  v_cleanup := public.direct_order_cleanup_expired_pii(ARRAY[v_request]);
  INSERT INTO _direct_delivery_results VALUES (
    'retention removes exact PII but preserves coarse and financial facts',
    (v_cleanup->>'requests')::integer = 1
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_order_request_addresses
        WHERE request_id = v_request
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_order_messages
        WHERE request_id = v_request
      )
      AND EXISTS (
        SELECT 1 FROM public.direct_order_location_facts
        WHERE request_id = v_request
      )
      AND EXISTS (
        SELECT 1 FROM public.direct_order_requests
        WHERE id = v_request AND pii_purged_at IS NOT NULL
      ),
    'exact address/chat removed after configured retention'
  );
END;
$contract$;

DO $assertions$
DECLARE
  v_failed text;
BEGIN
  SELECT string_agg(scenario || ': ' || COALESCE(detail, ''), E'\n')
  INTO v_failed
  FROM _direct_delivery_results
  WHERE NOT ok;
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_CONTRACT_FAILED:%', E'\n' || v_failed;
  END IF;
END;
$assertions$;

SELECT scenario, detail
FROM _direct_delivery_results
ORDER BY scenario;

ROLLBACK;
