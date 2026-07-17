\set ON_ERROR_STOP on

CREATE TEMP TABLE approved_restaurant_cutoff_stores (
  store_id uuid PRIMARY KEY
) ON COMMIT PRESERVE ROWS;

INSERT INTO approved_restaurant_cutoff_stores (store_id)
SELECT DISTINCT btrim(value)::uuid
FROM unnest(string_to_array(:'restaurant_cutoff_store_ids', ',')) value
WHERE btrim(value) <> '';

DO $$
DECLARE
  v_invalid integer;
  v_photo_overlap integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM approved_restaurant_cutoff_stores) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_APPROVED_STORE_REQUIRED';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM approved_restaurant_cutoff_stores approved
  LEFT JOIN public.restaurants store ON store.id = approved.store_id
  WHERE store.id IS NULL OR store.is_active IS DISTINCT FROM true;
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_APPROVED_STORE_INVALID: %', v_invalid;
  END IF;

  IF to_regclass('public.photo_objet_monitoring_policies') IS NOT NULL THEN
    SELECT count(*) INTO v_photo_overlap
    FROM approved_restaurant_cutoff_stores approved
    JOIN public.photo_objet_monitoring_policies photo
      ON photo.store_id = approved.store_id
     AND photo.is_enabled = true
     AND photo.effective_to IS NULL;
  END IF;
  IF v_photo_overlap <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_PHOTO_STORE_FORBIDDEN: %', v_photo_overlap;
  END IF;
END $$;

INSERT INTO public.restaurant_cutoff_policies (
  restaurant_id,
  is_enabled,
  updated_at
)
SELECT approved.store_id, true, statement_timestamp()
FROM approved_restaurant_cutoff_stores approved
ON CONFLICT (restaurant_id) DO UPDATE
SET is_enabled = true,
    updated_at = EXCLUDED.updated_at;

DO $$
DECLARE
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_missing
  FROM approved_restaurant_cutoff_stores approved
  LEFT JOIN public.restaurant_cutoff_policies policy
    ON policy.restaurant_id = approved.store_id
   AND policy.is_enabled = true
  WHERE policy.restaurant_id IS NULL;
  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_CONFIGURATION_FAILED: %', v_missing;
  END IF;
END $$;

SELECT 'RESTAURANT_CUTOFF_CONFIGURATION_OK' AS result;
