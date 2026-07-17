DO $$
DECLARE
  v_required text[] := ARRAY[
    'public.restaurants',
    'public.tables',
    'public.printer_destinations',
    'public.print_jobs',
    'public.audit_logs'
  ];
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY v_required LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'STORE_SETUP_PREFLIGHT_MISSING_RELATION:%', v_relation;
    END IF;
  END LOOP;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.admin_create_table(uuid,text,integer,text)') IS NULL
     OR to_regprocedure('public.admin_update_table(uuid,uuid,text,integer,text,numeric,numeric,numeric,numeric,integer,text,integer,text)') IS NULL
     OR to_regprocedure('public.admin_upsert_printer_destination(uuid,uuid,text,text,integer,text,text,boolean)') IS NULL
     OR to_regprocedure('public.admin_enqueue_printer_test_job(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_PREFLIGHT_MISSING_RPC_DEPENDENCY';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.printer_destinations
    WHERE is_active = true
    GROUP BY restaurant_id, lower(btrim(purpose)),
      COALESCE(upper(btrim(floor_label)), '')
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'STORE_SETUP_DUPLICATE_ACTIVE_ROUTE_PREFLIGHT';
  END IF;
END;
$$;

SELECT 'STORE_SETUP_PREFLIGHT_OK' AS result;
