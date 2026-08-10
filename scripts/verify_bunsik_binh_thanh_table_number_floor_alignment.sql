DO $verification$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;
  v_audit jsonb;
  v_expected integer;
  v_current integer;
BEGIN
  SELECT details
  INTO v_audit
  FROM public.audit_logs
  WHERE action = 'migration_align_binh_thanh_table_numbers'
    AND entity_type = 'restaurants'
    AND entity_id = v_store_id
    AND details->>'migration' = '20260810150000'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_audit IS NULL THEN
    RAISE EXCEPTION 'BINH_THANH_TABLE_NUMBER_AUDIT_MISSING';
  END IF;

  v_expected := (v_audit->>'renamed_count')::integer;

  SELECT count(*)
  INTO v_current
  FROM jsonb_array_elements(v_audit->'renamed_tables') renamed(value)
  JOIN public.tables current_table
    ON current_table.id = (renamed.value->>'table_id')::uuid
   AND current_table.restaurant_id = v_store_id
   AND current_table.table_number = renamed.value->>'new_table_number';

  IF v_expected <= 0 OR v_current <> v_expected THEN
    RAISE EXCEPTION
      'BINH_THANH_TABLE_NUMBER_VERIFY_FAILED expected=% current=%',
      v_expected,
      v_current;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tables
    WHERE restaurant_id = v_store_id
      AND (
        (upper(btrim(floor_label)) = '2F' AND btrim(table_number) ~ '^2[0-9]{3}$')
        OR
        (upper(btrim(floor_label)) = '3F' AND btrim(table_number) ~ '^3[0-9]{3}$')
      )
  ) THEN
    RAISE EXCEPTION 'BINH_THANH_OLD_TABLE_NUMBER_REMAINS';
  END IF;

  RAISE NOTICE
    'Binh Thanh table-number alignment verified for % stable table IDs',
    v_current;
END;
$verification$;
