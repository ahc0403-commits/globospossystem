DO $$
DECLARE item record; operation text; statement text; current_rows jsonb;
BEGIN
  FOR item IN SELECT * FROM retirement_history_before LOOP
    EXECUTE format('SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.%I t', item.table_name) INTO current_rows;
    IF current_rows IS DISTINCT FROM item.rows THEN
      RAISE EXCEPTION 'Retirement changed history: %',item.table_name;
    END IF;
    FOREACH operation IN ARRAY ARRAY['insert','update','delete','truncate'] LOOP
      statement := CASE operation
        WHEN 'insert' THEN format('INSERT INTO public.%I SELECT * FROM public.%I',item.table_name,item.table_name)
        WHEN 'update' THEN format('UPDATE public.%I SET id=id',item.table_name)
        WHEN 'delete' THEN format('DELETE FROM public.%I',item.table_name)
        ELSE format('TRUNCATE public.%I CASCADE',item.table_name) END;
      BEGIN
        EXECUTE statement;
        RAISE EXCEPTION 'Retired operation unexpectedly succeeded: %',statement;
      EXCEPTION WHEN SQLSTATE 'P0001' THEN
        IF SQLERRM <> 'DELIBERRY_INTEGRATION_RETIRED' THEN RAISE; END IF;
      END;
    END LOOP;
  END LOOP;
  IF (SELECT array_agg(jobid ORDER BY jobid) FROM cron.job) <> ARRAY[4,5]::bigint[] THEN
    RAISE EXCEPTION 'Unrelated schedules were changed or retired schedules remain';
  END IF;
END;
$$;

-- Service-role BYPASSRLS cannot invoke mutation/retry RPCs or write ledgers.
SET ROLE service_role;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.deliberry_operational_orders) <> 1
     OR (SELECT count(*) FROM public.external_sales) <> 1 THEN
    RAISE EXCEPTION 'Historical SELECT is unavailable';
  END IF;
  BEGIN
    PERFORM public.receive_deliberry_operational_order(
      'a2000000-0000-4000-8000-000000000001','new-order','new-event','{}');
    RAISE EXCEPTION 'Retired RPC unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.get_deliberry_operational_order_events_for_retry(
      'a2000000-0000-4000-8000-000000000001',100);
    RAISE EXCEPTION 'Retry RPC unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.delivery_settlements SET status='received';
    RAISE EXCEPTION 'Retired settlement unexpectedly changed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
SET ROLE authenticated;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.delivery_settlements) <> 1 THEN
    RAISE EXCEPTION 'Historical settlement SELECT is unavailable';
  END IF;
  BEGIN
    PERFORM public.confirm_delivery_settlement_received(
      'a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'Retired confirmation unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- ALWAYS triggers also reject writes while a replication role is selected.
SET session_replication_role=replica;
DO $$
BEGIN
  BEGIN
    UPDATE public.external_sales SET gross_amount=1;
    RAISE EXCEPTION 'Replication role bypassed retirement';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'DELIBERRY_INTEGRATION_RETIRED' THEN RAISE; END IF;
  END;
END;
$$;
SET session_replication_role=origin;

-- A future non-Deliberry provider in the shared relation remains unaffected.
ALTER TABLE public.external_sales DROP CONSTRAINT external_sales_source_system_check;
INSERT INTO public.external_sales(restaurant_id,source_system,external_order_id,gross_amount,net_amount,order_status)
VALUES('a2000000-0000-4000-8000-000000000001','other-provider','other-order',100,100,'completed');
UPDATE public.external_sales SET gross_amount=200 WHERE source_system='other-provider';
DELETE FROM public.external_sales WHERE source_system='other-provider';
-- Normal POS orders and payments continue to work.
INSERT INTO public.orders VALUES('a6000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001','delivery','completed');
INSERT INTO public.payments VALUES('a6000000-0000-4000-8000-000000000001',100000,now(),true);

SELECT 'DELIBERRY_RETIREMENT_BEHAVIOR_OK' AS result;
