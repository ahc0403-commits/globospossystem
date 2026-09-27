\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $verify$
BEGIN
  IF to_regprocedure('public.search_inventory_workflow_orders(uuid,text[],boolean,integer,integer,text)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_ORDER_SEARCH_MISSING';
  END IF;
  IF NOT has_function_privilege('authenticated',
      'public.search_inventory_workflow_orders(uuid,text[],boolean,integer,integer,text)', 'EXECUTE')
    OR has_function_privilege('anon',
      'public.search_inventory_workflow_orders(uuid,text[],boolean,integer,integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_ORDER_SEARCH_GRANT_INVALID';
  END IF;
END $verify$;
SELECT 'inventory workflow order search verified' AS result;
ROLLBACK;
