\set ON_ERROR_STOP on
BEGIN;
\ir ../supabase/migrations/20261001020000_daily_table_operational_reset.sql

-- Initial rollout: the restaurant identified in the incident only. Match the
-- existing store by name and refuse ambiguous identity rather than guessing.
DO $$
DECLARE v_store uuid; v_incident public.orders%ROWTYPE;
BEGIN
  IF (SELECT count(*) FROM public.restaurants WHERE name='BunsikClub Binh Thanh' AND is_active)<>1 THEN
    RAISE EXCEPTION 'BUNSIK_RESET_STORE_IDENTITY_AMBIGUOUS'; END IF;
  SELECT id INTO v_store FROM public.restaurants WHERE name='BunsikClub Binh Thanh' AND is_active;
  SELECT * INTO v_incident FROM public.orders
  WHERE id='a797c8d3-0315-4f91-8a71-66c40c8db945' AND restaurant_id=v_store FOR UPDATE;
  IF FOUND AND v_incident.status IN ('pending','confirmed','serving')
    AND EXISTS(SELECT 1 FROM public.payments WHERE order_id=v_incident.id) THEN
    RAISE EXCEPTION 'INCIDENT_PAYMENT_CHANGED_REVIEW_REQUIRED'; END IF;
  INSERT INTO public.table_operational_reset_policies(restaurant_id,is_enabled) VALUES(v_store,true);
  -- One atomic catch-up closes the confirmed incident and any other previous
  -- days left open. The immutable ledger contains the before-image of each.
  PERFORM public.close_expired_table_operations_at(v_store,clock_timestamp());
  IF EXISTS(SELECT 1 FROM public.order_operational_closures WHERE order_id=v_incident.id AND closure_kind='unpaid_cancelled') THEN
    INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
    VALUES(NULL,'recover_stale_1222','orders',v_incident.id,jsonb_build_object(
      'source','system','reason','No guests confirmed; previous-day order; recovery-test additions included'));
  END IF;
END;
$$;
COMMIT;
