BEGIN;

-- Align Bunsik Club Binh Thanh table numbers with the guest-facing floor
-- labels introduced by the G/1F/2F display mapping. Table UUIDs remain stable,
-- so orders and QR tokens keep their existing foreign-key identity.
LOCK TABLE public.tables IN SHARE ROW EXCLUSIVE MODE;

DO $preflight$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;
  v_floor_2_count integer;
  v_floor_3_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = v_store_id
  ) THEN
    RAISE EXCEPTION 'BINH_THANH_STORE_NOT_FOUND';
  END IF;

  SELECT
    count(*) FILTER (
      WHERE upper(btrim(floor_label)) = '2F'
        AND btrim(table_number) ~ '^2[0-9]{3}$'
    ),
    count(*) FILTER (
      WHERE upper(btrim(floor_label)) = '3F'
        AND btrim(table_number) ~ '^3[0-9]{3}$'
    )
  INTO v_floor_2_count, v_floor_3_count
  FROM public.tables
  WHERE restaurant_id = v_store_id;

  IF v_floor_2_count = 0 OR v_floor_3_count = 0 THEN
    RAISE EXCEPTION
      'BINH_THANH_TABLE_NUMBER_SOURCE_MISSING floor_2=% floor_3=%',
      v_floor_2_count,
      v_floor_3_count;
  END IF;
END;
$preflight$;

CREATE TEMP TABLE floor_table_number_alignment ON COMMIT DROP AS
SELECT
  id,
  table_number AS old_table_number,
  CASE upper(btrim(floor_label))
    WHEN '2F' THEN '1' || substr(btrim(table_number), 2)
    WHEN '3F' THEN '2' || substr(btrim(table_number), 2)
  END AS new_table_number
FROM public.tables
WHERE restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
  AND (
    (upper(btrim(floor_label)) = '2F' AND btrim(table_number) ~ '^2[0-9]{3}$')
    OR
    (upper(btrim(floor_label)) = '3F' AND btrim(table_number) ~ '^3[0-9]{3}$')
  );

DO $collision_check$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM floor_table_number_alignment desired
    JOIN public.tables existing
      ON existing.restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
     AND upper(btrim(existing.table_number)) =
         upper(btrim(desired.new_table_number))
     AND existing.id <> desired.id
    LEFT JOIN floor_table_number_alignment moving
      ON moving.id = existing.id
    WHERE moving.id IS NULL
  ) THEN
    RAISE EXCEPTION 'BINH_THANH_TABLE_NUMBER_TARGET_COLLISION';
  END IF;
END;
$collision_check$;

-- Move every source row through a UUID-based temporary value so the existing
-- per-store unique constraint cannot be tripped by overlapping 2XXX targets.
UPDATE public.tables AS target
SET
  table_number = '__floor_alignment__' || replace(target.id::text, '-', ''),
  updated_at = now()
FROM floor_table_number_alignment AS desired
WHERE target.id = desired.id;

UPDATE public.tables AS target
SET
  table_number = desired.new_table_number,
  updated_at = now()
FROM floor_table_number_alignment AS desired
WHERE target.id = desired.id;

DO $verification$
DECLARE
  v_expected integer;
  v_updated integer;
BEGIN
  SELECT count(*) INTO v_expected FROM floor_table_number_alignment;

  SELECT count(*)
  INTO v_updated
  FROM floor_table_number_alignment desired
  JOIN public.tables current_table
    ON current_table.id = desired.id
   AND current_table.restaurant_id =
       '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
   AND current_table.table_number = desired.new_table_number;

  IF v_updated <> v_expected THEN
    RAISE EXCEPTION
      'BINH_THANH_TABLE_NUMBER_VERIFY_FAILED expected=% updated=%',
      v_expected,
      v_updated;
  END IF;
END;
$verification$;

INSERT INTO public.audit_logs (
  actor_id,
  action,
  entity_type,
  entity_id,
  details
)
SELECT
  NULL,
  'migration_align_binh_thanh_table_numbers',
  'restaurants',
  '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
  jsonb_build_object(
    'migration', '20260810150000',
    'renamed_count', count(*),
    'renamed_tables', jsonb_agg(
      jsonb_build_object(
        'table_id', id,
        'old_table_number', old_table_number,
        'new_table_number', new_table_number
      )
      ORDER BY old_table_number
    ),
    'qr_identity', 'table_id preserved',
    'printer_configuration', 'unchanged'
  )
FROM floor_table_number_alignment;

COMMIT;
