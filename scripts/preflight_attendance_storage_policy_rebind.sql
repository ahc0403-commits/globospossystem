DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'storage.objects'::regclass
      AND polname = 'inventory_receipt_statement_objects_write'
      AND polcmd = 'a' AND polpermissive
      AND polroles = ARRAY['authenticated'::regrole::oid]
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_STORAGE_POLICY_PRECONDITION_CHANGED';
  END IF;
  IF NOT has_function_privilege('authenticated',
      'public.can_create_inventory_purchase_order(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated',
      'public.can_verify_inventory_receipt(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ATTENDANCE_STORAGE_CURRENT_HELPER_NOT_EXECUTABLE';
  END IF;
END;
$preflight$;
