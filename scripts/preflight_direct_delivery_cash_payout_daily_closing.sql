\set ON_ERROR_STOP on
DO $preflight$
DECLARE v_function text; v_digest text;
BEGIN
  FOR v_function, v_digest IN SELECT * FROM (VALUES
    ('public.direct_order_set_dispatch(uuid,uuid,text,numeric)', 'd3197fa1c9145a6147bd47330ab3eeb9'),
    ('public.get_daily_closing_cash_preview(uuid,date)', '8b75d6ff3d65a423b66fb1dd0d195b8a'),
    ('public.create_daily_closing(uuid,text,jsonb,numeric,date)', '90ad3bc32856ed0abf47271a3534a417'),
    ('public.get_daily_closing_days(uuid,integer)', '41f47793613d85a9018f0c440662bb27')
  ) AS expected(signature, digest) LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_function::regprocedure) <> v_digest THEN
      RAISE EXCEPTION 'CASH_PAYOUT_PREDECESSOR_DRIFT: %', v_function;
    END IF;
  END LOOP;
END;
$preflight$;

