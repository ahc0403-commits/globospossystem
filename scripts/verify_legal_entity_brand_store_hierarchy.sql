-- Non-destructive forward verification. Safe to run repeatedly after migration.
DO $verify$
DECLARE
  v_backup_count integer;
BEGIN
  IF to_regclass('public.hierarchy_20260711090000_backup_state') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_photo_backup') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_history_backup') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_object_backup') IS NULL
     OR to_regclass('public.tax_entity_brands') IS NULL
     OR to_regclass('public.v_office_eligible_stores') IS NULL THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_MIGRATION_ARTIFACT_MISSING';
  END IF;

  IF 1 <> (
    SELECT count(*)
    FROM public.hierarchy_20260711090000_backup_state
    WHERE singleton = true
      AND snapshot_completed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_BACKUP_SNAPSHOT_INCOMPLETE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_history_backup
    WHERE COALESCE(reason, '') LIKE 'hierarchy_20260711090000_photo_objet_source;%'
       OR COALESCE(reason, '') LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_BACKUP_CONTAINS_GENERATED_HISTORY';
  END IF;

  SELECT count(*) INTO v_backup_count
  FROM public.hierarchy_20260711090000_photo_backup;
  IF v_backup_count <> 7 THEN
    RAISE EXCEPTION
      'HIERARCHY_VERIFY_PHOTO_BACKUP_COUNT expected=7 actual=%', v_backup_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurants r
    LEFT JOIN public.tax_entity_brands teb
      ON teb.tax_entity_id = r.tax_entity_id AND teb.brand_id = r.brand_id
    WHERE r.tax_entity_id IS NOT NULL
      AND r.brand_id IS NOT NULL
      AND teb.tax_entity_id IS NULL
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_INVALID_ENTITY_BRAND_STORE_TUPLE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurants r
    JOIN public.tax_entity te ON te.id = r.tax_entity_id
    WHERE r.store_type IS DISTINCT FROM CASE te.owner_type
      WHEN 'internal' THEN 'direct'
      WHEN 'external' THEN 'external'
    END
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_STORE_TYPE_PROJECTION_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    LEFT JOIN public.restaurants r ON r.id = b.store_id
    WHERE r.id IS NULL
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_PHOTO_STORE_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    JOIN public.restaurants r ON r.id = b.store_id
    WHERE r.tax_entity_id <> 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_PHOTO_BACKFILL_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    WHERE NOT EXISTS (
      SELECT 1 FROM public.store_tax_entity_history h
      WHERE h.store_id = b.store_id
        AND h.tax_entity_id = b.prior_tax_entity_id
        AND h.effective_to = b.captured_at
    ) OR 1 <> (
      SELECT count(*) FROM public.store_tax_entity_history h
      WHERE h.store_id = b.store_id
        AND h.tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
        AND h.effective_to IS NULL
        AND h.reason LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
    )
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_PHOTO_HISTORY_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.v_office_eligible_stores v
    JOIN public.tax_entity te ON te.id = v.tax_entity_id
    WHERE te.owner_type <> 'internal'
  ) OR EXISTS (
    SELECT 1 FROM public.restaurants r
    JOIN public.tax_entity te ON te.id = r.tax_entity_id
    WHERE te.owner_type = 'internal'
      AND NOT EXISTS (
        SELECT 1 FROM public.v_office_eligible_stores v WHERE v.store_id = r.id
      )
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_OFFICE_ELIGIBILITY_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.meinvoice_tax_entity_config c
    JOIN public.tax_entity te ON te.id = c.tax_entity_id
    WHERE te.onboarding_status = 'pending_tax_profile'
      AND c.integration_status = 'active'
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_VERIFY_PENDING_ENTITY_ACTIVE_FOR_MEINVOICE';
  END IF;
END;
$verify$;

SELECT 'hierarchy verification passed' AS result;
