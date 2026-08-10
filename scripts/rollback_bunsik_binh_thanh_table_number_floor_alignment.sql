BEGIN;

LOCK TABLE public.tables IN SHARE ROW EXCLUSIVE MODE;

CREATE TEMP TABLE floor_table_number_rollback ON COMMIT DROP AS
SELECT
  (renamed.value->>'table_id')::uuid AS id,
  renamed.value->>'old_table_number' AS old_table_number,
  renamed.value->>'new_table_number' AS new_table_number
FROM public.audit_logs audit
CROSS JOIN LATERAL jsonb_array_elements(
  audit.details->'renamed_tables'
) renamed(value)
WHERE audit.action = 'migration_align_binh_thanh_table_numbers'
  AND audit.entity_type = 'restaurants'
  AND audit.entity_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
  AND audit.details->>'migration' = '20260810150000'
  AND audit.id = (
    SELECT latest.id
    FROM public.audit_logs latest
    WHERE latest.action = 'migration_align_binh_thanh_table_numbers'
      AND latest.entity_type = 'restaurants'
      AND latest.entity_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND latest.details->>'migration' = '20260810150000'
    ORDER BY latest.created_at DESC
    LIMIT 1
  );

DO $rollback_preflight$
DECLARE
  v_expected integer;
  v_current integer;
BEGIN
  SELECT count(*) INTO v_expected FROM floor_table_number_rollback;
  IF v_expected = 0 THEN
    RAISE EXCEPTION 'BINH_THANH_TABLE_NUMBER_ROLLBACK_AUDIT_MISSING';
  END IF;

  SELECT count(*)
  INTO v_current
  FROM floor_table_number_rollback rollback_row
  JOIN public.tables current_table
    ON current_table.id = rollback_row.id
   AND current_table.restaurant_id =
       '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
   AND current_table.table_number = rollback_row.new_table_number;

  IF v_current <> v_expected THEN
    RAISE EXCEPTION
      'BINH_THANH_TABLE_NUMBER_ROLLBACK_STATE_CHANGED expected=% current=%',
      v_expected,
      v_current;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM floor_table_number_rollback desired
    JOIN public.tables existing
      ON existing.restaurant_id =
          '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
     AND upper(btrim(existing.table_number)) =
         upper(btrim(desired.old_table_number))
     AND existing.id <> desired.id
    LEFT JOIN floor_table_number_rollback moving ON moving.id = existing.id
    WHERE moving.id IS NULL
  ) THEN
    RAISE EXCEPTION 'BINH_THANH_TABLE_NUMBER_ROLLBACK_COLLISION';
  END IF;
END;
$rollback_preflight$;

UPDATE public.tables AS target
SET
  table_number = '__floor_rollback__' || replace(target.id::text, '-', ''),
  updated_at = now()
FROM floor_table_number_rollback AS rollback_row
WHERE target.id = rollback_row.id;

UPDATE public.tables AS target
SET
  table_number = rollback_row.old_table_number,
  updated_at = now()
FROM floor_table_number_rollback AS rollback_row
WHERE target.id = rollback_row.id;

INSERT INTO public.audit_logs (
  actor_id,
  action,
  entity_type,
  entity_id,
  details
)
SELECT
  NULL,
  'rollback_align_binh_thanh_table_numbers',
  'restaurants',
  '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
  jsonb_build_object(
    'migration', '20260810150000',
    'restored_count', count(*)
  )
FROM floor_table_number_rollback;

COMMIT;
