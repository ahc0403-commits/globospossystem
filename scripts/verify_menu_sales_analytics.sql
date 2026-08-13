\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_definition text;
  v_missing integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.payment_adjustments') IS NULL
     OR to_regprocedure(
       'public.capture_order_item_menu_identity()'
     ) IS NULL
     OR to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_OBJECT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_items'
      AND column_name = 'menu_item_id_snapshot'
      AND data_type = 'uuid'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_SNAPSHOT_COLUMN_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items
    WHERE menu_item_id IS NOT NULL
      AND menu_item_id_snapshot IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_SNAPSHOT_BACKFILL_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgname =
      'capture_order_item_menu_identity_trigger'
      AND trigger_row.tgrelid = 'public.order_items'::regclass
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_TRIGGER_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid =
      'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'::regprocedure
      AND proc.prosecdef
      AND proc.provolatile = 's'
      AND proc.prorettype = 'jsonb'::regtype
      AND proc.proconfig @>
        ARRAY['search_path=public, auth, pg_catalog']::text[]
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_RPC_SECURITY_INVALID';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_RPC_PRIVILEGE_INVALID';
  END IF;

  v_definition := lower(pg_get_functiondef(
    'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'::regprocedure
  ));
  IF v_definition NOT LIKE
       '%require_admin_actor_for_restaurant(p_store_id)%'
     OR v_definition NOT LIKE '%max(payment.created_at)%'
     OR v_definition NOT LIKE '%payment.is_revenue = true%'
     OR v_definition NOT LIKE '%order_row.status = ''completed''%'
     OR v_definition NOT LIKE '%item.item_type = ''menu_item''%'
     OR v_definition NOT LIKE '%item.status <> ''cancelled''%'
     OR v_definition NOT LIKE '%is_service_item%'
     OR v_definition NOT LIKE
       '%at time zone ''asia/ho_chi_minh''%'
     OR v_definition NOT LIKE '%payment_adjustments%' THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_QUERY_CONTRACT_INVALID';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('restaurants', 'address'),
      ('restaurants', 'is_active')
  ) required(table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = 'public'
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;
  IF v_missing <> 0 OR EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.restaurants'::regclass
      AND relation.relkind NOT IN ('r', 'p')
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_OFFICE_CONTRACT_INVALID';
  END IF;

  IF to_regprocedure(
       'public.process_payment(uuid,uuid,numeric,text)'
     ) IS NULL
     OR to_regprocedure('public.create_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.add_items_to_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure(
       'public.create_buffet_order(uuid,uuid,integer,jsonb)'
     ) IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM pg_proc proc
       WHERE proc.oid =
         'public.process_payment(uuid,uuid,numeric,text)'::regprocedure
         AND proc.prosecdef
     ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_VERIFY_CORE_POS_CONTRACT_INVALID';
  END IF;
END
$verify$;

SELECT 'MENU_SALES_ANALYTICS_VERIFY_OK' AS result;
