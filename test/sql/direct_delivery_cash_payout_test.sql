\set ON_ERROR_STOP on
DO $test$
DECLARE
  v_store uuid; v_request uuid; v_actor uuid:=gen_random_uuid();
  v_result jsonb; v_paid_at timestamptz;
  v_day date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
  IF current_database()<>'codex_direct_manual' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
  -- Exercise dispatch/closing on a real manually-addressed request from the
  -- preceding submit regression, not fabricated coordinates or a live order.
  SELECT restaurant_id,request_id INTO STRICT v_store,v_request
    FROM direct_order_request_addresses WHERE address_source='manual' LIMIT 1;
  PERFORM set_config('fixture.store_id',v_store::text,true);
  INSERT INTO auth.users(id) VALUES(v_actor);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.users VALUES(v_actor,'Fixture Manager');
  INSERT INTO direct_order_financials VALUES(v_request,v_store,30000);
  INSERT INTO payments VALUES(gen_random_uuid(),v_store,true,'cash',100000,NULL,now());
  BEGIN
    PERFORM direct_order_set_dispatch(v_store,v_request,'https://grab.com/fixture',NULL);
    RAISE EXCEPTION 'MISSING_FEE_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'DIRECT_ORDER_DISPATCH_INPUT_INVALID' THEN RAISE; END IF;
  END;
  PERFORM direct_order_set_dispatch(v_store,v_request,'https://grab.com/fixture',25000);
  SELECT cash_paid_at INTO v_paid_at FROM direct_order_dispatches WHERE request_id=v_request;
  PERFORM direct_order_set_dispatch(v_store,v_request,'https://grab.com/updated-fixture',25000);
  IF (SELECT cash_paid_at FROM direct_order_dispatches WHERE request_id=v_request)<>v_paid_at THEN
    RAISE EXCEPTION 'PAYOUT_DATE_CHANGED_ON_LINK_UPDATE';
  END IF;
  BEGIN
    PERFORM direct_order_set_dispatch(v_store,v_request,'https://grab.com/fixture',26000);
    RAISE EXCEPTION 'PAID_FEE_CHANGE_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'DIRECT_ORDER_CASH_PAYOUT_LOCKED' THEN RAISE; END IF;
  END;
  v_result:=get_daily_closing_cash_preview(v_store,v_day);
  IF (v_result->>'payments_cash')::numeric<>100000
    OR (v_result->>'delivery_cash_payout')::numeric<>25000
    OR (v_result->>'expected_cash_amount')::numeric<>5075000 THEN
    RAISE EXCEPTION 'CASH_PREVIEW_MATH_INCORRECT';
  END IF;
  v_result:=create_daily_closing(v_store,NULL,'{"500000":10,"50000":1,"20000":1,"5000":1}',5000000,v_day);
  IF (v_result->>'expected_cash_amount')::numeric<>5075000
    OR (v_result->>'counted_cash_amount')::numeric<>5075000
    OR (v_result->>'cash_variance')::numeric<>0 THEN
    RAISE EXCEPTION 'PERSISTED_CASH_CLOSING_INCORRECT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM get_daily_closing_days(v_store,1)
    WHERE delivery_cash_payout=25000 AND expected_cash_amount=5075000 AND cash_variance=0) THEN
    RAISE EXCEPTION 'CASH_PAYOUT_HISTORY_INCORRECT';
  END IF;
  BEGIN
    PERFORM get_daily_closing_cash_preview(gen_random_uuid(),v_day);
    RAISE EXCEPTION 'CROSS_STORE_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'DAILY_CLOSING_FORBIDDEN' THEN RAISE; END IF;
  END;
END;
$test$;
