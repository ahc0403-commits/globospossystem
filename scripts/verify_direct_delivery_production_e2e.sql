\set ON_ERROR_STOP on

-- Production runtime verification that exercises one complete direct-delivery
-- graph and then rolls every write back. Invoke only with both variables:
--   psql ... -v confirm_direct_delivery_rollback_e2e=YES \
--     -v direct_order_e2e_store_slug=bunsikclub-sample \
--     -f scripts/verify_direct_delivery_production_e2e.sql
\if :{?confirm_direct_delivery_rollback_e2e}
\else
  \set confirm_direct_delivery_rollback_e2e NO
\endif
\if :{?direct_order_e2e_store_slug}
\else
  \set direct_order_e2e_store_slug bunsikclub-sample
\endif

BEGIN;
SELECT set_config(
  'codex.direct_delivery_e2e_confirm',
  :'confirm_direct_delivery_rollback_e2e',
  true
);
SELECT set_config(
  'codex.direct_delivery_e2e_store_slug',
  :'direct_order_e2e_store_slug',
  true
);

DO $verify$
DECLARE
  v_store uuid;
  v_actor uuid;
  v_menu uuid := gen_random_uuid();
  v_ingredient uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_secret_hash text := replace(gen_random_uuid()::text, '-', '') ||
    replace(gen_random_uuid()::text, '-', '');
  v_submit jsonb;
  v_quote jsonb;
  v_customer_message jsonb;
  v_request uuid;
  v_approval jsonb;
  v_order uuid;
  v_payment uuid;
  v_ticket uuid;
  v_transition jsonb;
  v_status jsonb;
  v_translations jsonb;
  v_analytics jsonb;
BEGIN
  IF current_setting('codex.direct_delivery_e2e_confirm') <> 'YES' THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_PRODUCTION_E2E_CONFIRMATION_REQUIRED';
  END IF;
  IF (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time >= time '21:30' THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_PRODUCTION_E2E_BEFORE_CUTOFF_REQUIRED';
  END IF;

  SELECT storefront.restaurant_id INTO v_store
  FROM public.direct_order_storefronts storefront
  JOIN public.restaurants restaurant
    ON restaurant.id = storefront.restaurant_id
  WHERE storefront.public_slug =
      current_setting('codex.direct_delivery_e2e_store_slug')
    AND restaurant.is_active
  FOR UPDATE OF storefront;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_PRODUCTION_E2E_STOREFRONT_NOT_FOUND';
  END IF;

  SELECT user_row.auth_id INTO v_actor
  FROM public.users user_row
  WHERE user_row.auth_id IS NOT NULL
    AND user_row.is_active
    AND user_row.role = ANY(
      ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
    )
    AND (
      user_row.role = 'super_admin'
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(user_row.auth_id) scope(store_id)
        WHERE scope.store_id = v_store
      )
    )
  ORDER BY CASE user_row.role
    WHEN 'admin' THEN 1
    WHEN 'store_admin' THEN 2
    WHEN 'brand_admin' THEN 3
    ELSE 4
  END, user_row.id
  LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_PRODUCTION_E2E_ADMIN_NOT_FOUND';
  END IF;

  -- Changes stay invisible outside this transaction and are rolled back.
  UPDATE public.direct_order_storefronts
  SET is_enabled = true,
      is_paused = false,
      ordering_starts_at = time '00:00',
      ordering_cutoff_at = time '21:30',
      accounting_approved_at = COALESCE(accounting_approved_at, now()),
      accounting_approved_by = COALESCE(accounting_approved_by, v_actor)
  WHERE restaurant_id = v_store;

  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en,
    price, vat_category, is_available, is_visible_public
  ) VALUES (
    v_menu, v_store, 'Rollback-only direct E2E item',
    '롤백 전용 직접 주문', 'Món kiểm thử hoàn tác',
    'Rollback-only direct order', 100000, 'food', true, true
  );
  INSERT INTO public.inventory_items(
    id, restaurant_id, name, quantity, unit, current_stock
  ) VALUES (
    v_ingredient, v_store, 'Rollback-only direct E2E ingredient',
    10000, 'g', 10000
  );
  INSERT INTO public.menu_recipes(
    restaurant_id, menu_item_id, ingredient_id, quantity_g
  ) VALUES (v_store, v_menu, v_ingredient, 10);

  INSERT INTO public.direct_order_sessions(
    id, restaurant_id, secret_hash, locale
  ) VALUES (v_session, v_store, v_secret_hash, 'en');

  v_submit := public.direct_order_public_submit(
    v_session,
    v_secret_hash,
    gen_random_uuid(),
    jsonb_build_object(
      'locale', 'en',
      'items', jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu,
        'quantity', 1,
        'note', 'rollback-only item note'
      )),
      'address', jsonb_build_object(
        'customer_name', 'Rollback Test Customer',
        'customer_phone', '+84901234567',
        'formatted_address', '123 Nguyen Hue, District 1, HCMC',
        'detail_address', 'Rollback-only floor 4',
        'latitude', 10.775,
        'longitude', 106.704,
        'google_place_id', 'rollback-only-place-id',
        'district', 'District 1',
        'ward', 'Ben Nghe',
        'address_source', 'search',
        'location_verified', true
      )
    )
  );
  v_request := (v_submit->>'request_id')::uuid;

  v_customer_message := public.direct_order_public_message_translated(
    v_session, v_secret_hash, v_request,
    'Please confirm the fourth-floor address.', 'en',
    '4층 주소를 확인해 주세요.',
    'Vui lòng xác nhận địa chỉ tầng 4.',
    'Please confirm the fourth-floor address.'
  );
  PERFORM public.direct_order_staff_message_translated(
    v_actor, v_store, v_request,
    'Địa chỉ đã được xác nhận.', 'vi',
    '주소가 확인되었습니다.',
    'Địa chỉ đã được xác nhận.',
    'The address has been confirmed.'
  );

  PERFORM set_config('request.jwt.claim.sub', v_actor::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_quote := public.direct_order_staff_quote(
    v_store, v_request, 25000, 'rollback-only delivery quote'
  );
  PERFORM public.direct_order_public_commit_proof(
    v_session,
    v_secret_hash,
    v_request,
    v_store::text || '/' || v_request::text || '/' ||
      gen_random_uuid()::text || '.jpg'
  );
  v_approval := public.direct_order_approve_payment(
    v_store,
    v_request,
    (v_quote->>'final_total')::numeric,
    'rollback-only-bank-reference'
  );
  v_order := (v_approval->>'order_id')::uuid;
  v_payment := (v_approval->>'payment_id')::uuid;
  v_ticket := (v_approval->>'ticket_id')::uuid;

  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, 1, 'preparing'
  );
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, (v_transition->>'version')::integer, 'ready'
  );
  PERFORM public.direct_order_set_dispatch(
    v_store,
    v_request,
    'https://grab.onelink.me/test/direct-order-production-rollback-e2e',
    30000
  );
  SELECT jsonb_build_object('version', ticket.version) INTO v_transition
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.id = v_ticket;
  PERFORM public.direct_delivery_ticket_transition(
    v_store, v_ticket, (v_transition->>'version')::integer, 'completed'
  );

  v_status := public.direct_order_public_status(
    v_session, v_secret_hash, v_request
  );
  v_translations := public.direct_order_public_message_translations(
    v_session,
    v_secret_hash,
    v_request,
    'vi',
    ARRAY[(v_customer_message->>'message_id')::uuid]
  );
  v_analytics := public.direct_order_analytics(
    v_store,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  );

  IF (v_status->>'state') <> 'approved'
     OR (v_status->'fulfillment'->>'status') <> 'completed'
     OR (v_status->'dispatch'->>'grab_tracking_url') <>
       'https://grab.onelink.me/test/direct-order-production-rollback-e2e'
     OR (v_translations->'translations'->0->>'body') <>
       'Vui lòng xác nhận địa chỉ tầng 4.'
     OR NOT EXISTS (
       SELECT 1 FROM public.orders order_row
       WHERE order_row.id = v_order
         AND order_row.sales_channel = 'delivery'
         AND order_row.status = 'completed'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.payments payment
       WHERE payment.id = v_payment
         AND payment.order_id = v_order
         AND payment.method = 'BANKTRANSFER'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.direct_order_financials financial
       WHERE financial.request_id = v_request
         AND financial.order_id = v_order
         AND financial.payment_id = v_payment
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.direct_order_dispatches dispatch
       WHERE dispatch.request_id = v_request
         AND dispatch.actual_grab_fee = 30000
         AND dispatch.fee_variance = dispatch.customer_delivery_fee - 30000
     )
     OR (v_analytics->'summary'->>'order_count')::integer < 1
     OR (SELECT count(*) FROM public.direct_order_financials
         WHERE request_id = v_request) <> 1
     OR (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets
         WHERE request_id = v_request) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_PRODUCTION_ROLLBACK_E2E_FAILED';
  END IF;
END;
$verify$;

SELECT 'DIRECT_DELIVERY_PRODUCTION_ROLLBACK_E2E_PASS' AS result;
ROLLBACK;
