DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regprocedure(
    'public.get_bm_menu_exception_history(uuid,timestamp with time zone,timestamp with time zone,text,boolean,text,timestamp with time zone,integer,integer)'
  ) IS NULL THEN
    v_missing := array_append(
      v_missing,
      'public.get_bm_menu_exception_history'
    );
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    v_missing := array_append(v_missing, 'public.orders');
  END IF;
  IF to_regclass('public.order_items') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_items');
  END IF;
  IF to_regclass('public.menu_items') IS NULL THEN
    v_missing := array_append(v_missing, 'public.menu_items');
  END IF;
  IF to_regclass('public.restaurants') IS NULL THEN
    v_missing := array_append(v_missing, 'public.restaurants');
  END IF;
  IF to_regclass('public.users') IS NULL THEN
    v_missing := array_append(v_missing, 'public.users');
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    v_missing := array_append(
      v_missing,
      'public.user_accessible_stores(uuid)'
    );
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      'BM original-order drilldown prerequisites are missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END;
$preflight$;
