DO $preflight$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;
  v_floor_2_count integer;
  v_floor_3_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurants WHERE id = v_store_id
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

  IF EXISTS (
    WITH desired AS (
      SELECT
        id,
        CASE upper(btrim(floor_label))
          WHEN '2F' THEN '1' || substr(btrim(table_number), 2)
          WHEN '3F' THEN '2' || substr(btrim(table_number), 2)
        END AS new_table_number
      FROM public.tables
      WHERE restaurant_id = v_store_id
        AND (
          (upper(btrim(floor_label)) = '2F' AND btrim(table_number) ~ '^2[0-9]{3}$')
          OR
          (upper(btrim(floor_label)) = '3F' AND btrim(table_number) ~ '^3[0-9]{3}$')
        )
    )
    SELECT 1
    FROM desired
    JOIN public.tables existing
      ON existing.restaurant_id = v_store_id
     AND upper(btrim(existing.table_number)) =
         upper(btrim(desired.new_table_number))
     AND existing.id <> desired.id
    LEFT JOIN desired moving ON moving.id = existing.id
    WHERE moving.id IS NULL
  ) THEN
    RAISE EXCEPTION 'BINH_THANH_TABLE_NUMBER_TARGET_COLLISION';
  END IF;

  RAISE NOTICE
    'Binh Thanh table-number alignment ready: 2XXX->1XXX %, 3XXX->2XXX %',
    v_floor_2_count,
    v_floor_3_count;
END;
$preflight$;
