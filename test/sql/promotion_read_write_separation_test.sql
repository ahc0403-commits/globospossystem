-- Uses actual scoped promotion/payment wrapper and a settlement spy. This
-- proves routing/rollback of the new guard, not a full payment-engine replay.
CREATE TABLE fixture_anchor_calls(amount numeric,method text);
CREATE OR REPLACE FUNCTION public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)
RETURNS public.payments LANGUAGE plpgsql AS $$
DECLARE v_payment public.payments;
BEGIN
  INSERT INTO fixture_anchor_calls VALUES ($3,$4);
  INSERT INTO payments VALUES(gen_random_uuid()) RETURNING * INTO v_payment;
  RETURN v_payment;
END $$;
DO $$
DECLARE v_store uuid := '10000000-0000-0000-0000-000000000001';
  v_order uuid := '30000000-0000-0000-0000-000000000001';
  v_before jsonb; v_detail text; v_count int;
BEGIN
  PERFORM fixture_assert((SELECT count(*)=1 FROM cron.job WHERE jobname='promotion-boundaries'), 'one real pg_cron job registered');
  PERFORM fixture_assert(current_setting('cron.launch_active_jobs')='off','fixture never runs scheduled jobs automatically');
  PERFORM fixture_reset();
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
  UPDATE promotion_schedule_cursor SET checked_at=NULL;
  SELECT run_due_store_promotions() INTO v_count;
  PERFORM fixture_assert(v_count=1,'initial scheduler reconciles one current-day order');
  TRUNCATE fixture_writes,pos_live_events;
  SELECT run_due_store_promotions() INTO v_count;
  PERFORM fixture_assert(v_count=0,'unchanged tick does not scan order promotions');
  PERFORM fixture_assert((SELECT count(*)=0 FROM fixture_writes),'unchanged tick causes no discount DML');
  PERFORM fixture_assert((SELECT count(*)=0 FROM pos_live_events),'unchanged tick emits no read feedback');
  UPDATE store_promotions SET starts_at=now()-interval '2 hours', ends_at=now()-interval '1 minute';
  UPDATE promotion_schedule_cursor SET checked_at=now()-interval '2 minutes';
  PERFORM run_due_store_promotions();
  PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM order_discounts WHERE status='active'),'scheduler expires an idle order without a client read');
  PERFORM fixture_assert((SELECT count(*)=1 FROM pos_live_events WHERE domain='orders'),'expiry emits the existing cashier invalidation');
  UPDATE store_promotions SET starts_at=now()-interval '1 minute', ends_at=now()+interval '1 hour';
  UPDATE promotion_schedule_cursor SET checked_at=now()-interval '2 minutes';
  PERFORM run_due_store_promotions();
  PERFORM fixture_assert(EXISTS(SELECT 1 FROM order_discounts WHERE status='active'),'scheduler applies start boundary');

  -- A tick missed a boundary. Refuse the old-price payment, roll back sync,
  -- then explicitly prepare before the cashier re-confirms the new total.
  UPDATE store_promotions SET ends_at=now()-interval '1 second', starts_at=now()-interval '1 hour';
  v_before := fixture_snapshot();
  BEGIN
    PERFORM process_payment(v_order,v_store,196,'CASH');
    RAISE EXCEPTION 'expected boundary rejection';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_detail=PG_EXCEPTION_DETAIL;
    PERFORM fixture_assert(SQLERRM='PAYMENT_AMOUNT_MISMATCH' AND v_detail='PROMOTION_PRICE_CHANGED','boundary rejects before settlement');
  END;
  PERFORM fixture_assert((SELECT count(*)=0 FROM fixture_anchor_calls),'rejected attempt never invokes settlement');
  PERFORM fixture_assert(fixture_snapshot()=v_before,'rejected attempt rolls back discount changes');
  PERFORM prepare_order_payment_promotions(v_store,ARRAY[v_order]);
  PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM order_discounts WHERE status='active'),'explicit recovery persists expiry');
  PERFORM process_payment(v_order,v_store,218,'CASH');
  PERFORM fixture_assert((SELECT count(*)=1 FROM fixture_anchor_calls WHERE amount=218 AND method='CASH'),'confirmed amount reaches preserved settlement anchor once');

  UPDATE store_promotions SET starts_at=now()-interval '1 minute',ends_at=now()+interval '1 hour';
  PERFORM prepare_order_payment_promotions(v_store,ARRAY[v_order]);
  PERFORM process_payment(v_order,v_store,50,'CASH');
  PERFORM fixture_assert((SELECT count(*)=2 FROM fixture_anchor_calls),'unchanged promotion permits existing partial-payment amount');
  UPDATE order_discounts SET approved_via='manager_pin',reason='manual fixture' WHERE status='active';
  v_before := order_promotion_fingerprint(v_order,v_store);
  PERFORM prepare_order_payment_promotions(v_store,ARRAY[v_order]);
  PERFORM fixture_assert(order_promotion_fingerprint(v_order,v_store)=v_before,'manual discount remains authoritative');
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
  BEGIN
    PERFORM prepare_order_payment_promotions(v_store,ARRAY[v_order]);
    RAISE EXCEPTION 'expected authorization rejection';
  EXCEPTION WHEN raise_exception THEN
    PERFORM fixture_assert(SQLERRM='PAYMENT_FORBIDDEN','waiter cannot perform payment preparation');
  END;
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
  BEGIN
    PERFORM process_payment(v_order,'10000000-0000-0000-0000-000000000002',1,'CASH');
    RAISE EXCEPTION 'expected store rejection';
  EXCEPTION WHEN raise_exception THEN
    PERFORM fixture_assert(SQLERRM='PAYMENT_FORBIDDEN','cross-store payment guard fails before any write');
  END;
  PERFORM fixture_assert((SELECT count(*)=2 FROM fixture_anchor_calls),'unauthorized actions cannot reach settlement');
END $$;
