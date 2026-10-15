DO $verify$
DECLARE
  v_policy oid;
BEGIN
  SELECT oid INTO STRICT v_policy FROM pg_policy
  WHERE polrelid = 'storage.objects'::regclass
    AND polname = 'inventory_receipt_statement_objects_write'
    AND polcmd = 'a' AND polpermissive
    AND polroles = ARRAY['authenticated'::regrole::oid];

  IF NOT EXISTS (
    SELECT 1 FROM pg_depend
    WHERE classid = 'pg_policy'::regclass AND objid = v_policy
      AND refclassid = 'pg_proc'::regclass
      AND refobjid = 'public.can_create_inventory_purchase_order(uuid)'::regprocedure
  ) OR EXISTS (
    SELECT 1 FROM pg_depend d JOIN pg_proc p ON p.oid = d.refobjid
    WHERE d.classid = 'pg_policy'::regclass AND d.objid = v_policy
      AND d.refclassid = 'pg_proc'::regclass
      AND (p.proname = 'procurement_pre_inbox_can_create_order'
        OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_STORAGE_POLICY_DEPENDENCY_INVALID';
  END IF;
  IF has_function_privilege('authenticated',
      'public.procurement_pre_inbox_can_create_order(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ATTENDANCE_STORAGE_PRIVATE_HELPER_EXPOSED';
  END IF;
END;
$verify$;
SELECT 'attendance storage policy verification passed' AS result;
