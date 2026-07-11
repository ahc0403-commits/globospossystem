-- DESTRUCTIVE ROLLBACK. Run only after forward verification has failed and the
-- deployment owner has approved reverting migration 20260711090000.
DO $guard$
BEGIN
  IF to_regclass('public.hierarchy_20260711090000_backup_state') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_photo_backup') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_history_backup') IS NULL
     OR to_regclass('public.hierarchy_20260711090000_object_backup') IS NULL THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_CAPTURE_MISSING';
  END IF;

  IF 1 <> (
    SELECT count(*)
    FROM public.hierarchy_20260711090000_backup_state
    WHERE singleton = true
      AND snapshot_completed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_CAPTURE_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    JOIN public.restaurants r ON r.id = b.store_id
    WHERE r.tax_entity_id <> 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
      OR r.brand_id <> b.prior_brand_id
      OR 1 <> (
        SELECT count(*) FROM public.store_tax_entity_history h
        WHERE h.store_id = b.store_id
          AND h.tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
          AND h.effective_to IS NULL
          AND h.reason LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
      )
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_REFUSED_PHOTO_MAPPING_CHANGED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.store_tax_entity_history h
    JOIN public.hierarchy_20260711090000_photo_backup b ON b.store_id = h.store_id
    WHERE h.created_at > b.captured_at
      AND COALESCE(h.reason, '') NOT LIKE 'hierarchy_20260711090000_photo_objet_source;%'
      AND COALESCE(h.reason, '') NOT LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_REFUSED_NEWER_HISTORY_EXISTS';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tax_entity
    WHERE id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
      AND tax_code = 'PENDING_AKJ_TAX_PROFILE'
      AND onboarding_status = 'pending_tax_profile'
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_REFUSED_AKJ_PROFILE_CHANGED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    JOIN public.brands brand ON brand.id = b.prior_brand_id
    WHERE brand.suggested_tax_entity_id IS DISTINCT FROM
      'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_REFUSED_BRAND_SUGGESTION_CHANGED';
  END IF;
END;
$guard$;

ALTER TABLE public.restaurants
  DROP CONSTRAINT IF EXISTS restaurants_tax_entity_brand_fk;

DROP TRIGGER IF EXISTS trg_sync_restaurant_store_type_from_tax_entity ON public.restaurants;
DROP TRIGGER IF EXISTS trg_sync_stores_after_tax_entity_owner_change ON public.tax_entity;
DROP TRIGGER IF EXISTS trg_guard_pending_tax_entity_meinvoice_activation
  ON public.meinvoice_tax_entity_config;

UPDATE public.restaurants r
SET tax_entity_id = b.prior_tax_entity_id
FROM public.hierarchy_20260711090000_photo_backup b
WHERE r.id = b.store_id;

DELETE FROM public.store_tax_entity_history h
USING public.hierarchy_20260711090000_photo_backup b
WHERE h.store_id = b.store_id
  AND (
    h.reason LIKE 'hierarchy_20260711090000_photo_objet_source;%'
    OR h.reason LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
  );

UPDATE public.store_tax_entity_history h
SET store_id = b.store_id,
    tax_entity_id = b.tax_entity_id,
    effective_from = b.effective_from,
    effective_to = b.effective_to,
    reason = b.reason,
    created_at = b.created_at,
    created_by = b.created_by
FROM public.hierarchy_20260711090000_history_backup b
WHERE h.id = b.id;

INSERT INTO public.store_tax_entity_history
SELECT b.*
FROM public.hierarchy_20260711090000_history_backup b
WHERE NOT EXISTS (
  SELECT 1 FROM public.store_tax_entity_history h WHERE h.id = b.id
);

UPDATE public.brands brand
SET suggested_tax_entity_id = restored.prior_brand_suggested_tax_entity_id
FROM (
  SELECT DISTINCT prior_brand_id, prior_brand_suggested_tax_entity_id
  FROM public.hierarchy_20260711090000_photo_backup
) restored
WHERE brand.id = restored.prior_brand_id;

DO $assert_restored$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.restaurants r
      WHERE r.id = b.store_id
        AND r.tax_entity_id = b.prior_tax_entity_id
        AND r.brand_id = b.prior_brand_id
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_photo_backup b
    JOIN public.brands brand ON brand.id = b.prior_brand_id
    WHERE brand.suggested_tax_entity_id IS DISTINCT FROM
      b.prior_brand_suggested_tax_entity_id
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_RESTORE_MAPPING_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      (
        SELECT h.id, h.store_id, h.tax_entity_id, h.effective_from,
               h.effective_to, h.reason, h.created_at, h.created_by
        FROM public.store_tax_entity_history h
        JOIN public.hierarchy_20260711090000_photo_backup p
          ON p.store_id = h.store_id
        EXCEPT
        SELECT b.id, b.store_id, b.tax_entity_id, b.effective_from,
               b.effective_to, b.reason, b.created_at, b.created_by
        FROM public.hierarchy_20260711090000_history_backup b
      )
      UNION ALL
      (
        SELECT b.id, b.store_id, b.tax_entity_id, b.effective_from,
               b.effective_to, b.reason, b.created_at, b.created_by
        FROM public.hierarchy_20260711090000_history_backup b
        EXCEPT
        SELECT h.id, h.store_id, h.tax_entity_id, h.effective_from,
               h.effective_to, h.reason, h.created_at, h.created_by
        FROM public.store_tax_entity_history h
        JOIN public.hierarchy_20260711090000_photo_backup p
          ON p.store_id = h.store_id
      )
    ) history_difference
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_RESTORE_HISTORY_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.store_tax_entity_history h
    JOIN public.hierarchy_20260711090000_photo_backup b ON b.store_id = h.store_id
    WHERE COALESCE(h.reason, '') LIKE 'hierarchy_20260711090000_photo_objet_source;%'
       OR COALESCE(h.reason, '') LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_ROLLBACK_GENERATED_HISTORY_REMAINS';
  END IF;
END;
$assert_restored$;

DROP FUNCTION IF EXISTS public.admin_upsert_tax_entity_v2(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS public.admin_set_tax_entity_brand_link_v2(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS public.admin_create_restaurant_v2(text, text, text, uuid, uuid, text, numeric, uuid);
DROP FUNCTION IF EXISTS public.admin_update_restaurant_v2(uuid, text, text, text, uuid, uuid, text, numeric, uuid);
DROP FUNCTION IF EXISTS public.link_office_pending_store_for_pos_store_v2(uuid, text, uuid, uuid, text, uuid);
DROP FUNCTION IF EXISTS public.sync_restaurant_store_type_from_tax_entity();
DROP FUNCTION IF EXISTS public.sync_stores_after_tax_entity_owner_change();
DROP FUNCTION IF EXISTS public.guard_pending_tax_entity_meinvoice_activation();
DROP FUNCTION IF EXISTS public.admin_create_restaurant(text, text, text, text, numeric, uuid, text, uuid);
DROP FUNCTION IF EXISTS public.admin_update_restaurant(uuid, text, text, text, text, numeric, uuid, text);

DO $restore_functions$
DECLARE
  v_definition text;
BEGIN
  FOR v_definition IN
    SELECT definition
    FROM public.hierarchy_20260711090000_object_backup
    WHERE object_kind = 'function'
    ORDER BY object_identity
  LOOP
    EXECUTE v_definition;
  END LOOP;
END;
$restore_functions$;

DO $restore_triggers$
DECLARE
  v_definition text;
BEGIN
  FOR v_definition IN
    SELECT definition
    FROM public.hierarchy_20260711090000_object_backup
    WHERE object_kind = 'trigger'
    ORDER BY object_identity
  LOOP
    EXECUTE v_definition;
  END LOOP;
END;
$restore_triggers$;

DROP VIEW IF EXISTS public.v_office_eligible_stores;
DROP INDEX IF EXISTS public.idx_restaurants_tax_entity_brand;

DELETE FROM public.tax_entity_brands
WHERE tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid;
DELETE FROM public.tax_entity
WHERE id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  AND tax_code = 'PENDING_AKJ_TAX_PROFILE'
  AND NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  );

DROP TABLE IF EXISTS public.tax_entity_brands;
ALTER TABLE public.tax_entity DROP COLUMN IF EXISTS onboarding_status;
DROP TABLE public.hierarchy_20260711090000_history_backup;
DROP TABLE public.hierarchy_20260711090000_photo_backup;
DROP TABLE public.hierarchy_20260711090000_object_backup;
DROP TABLE public.hierarchy_20260711090000_backup_state;

SELECT 'hierarchy rollback completed; repair migration history to reverted' AS result;
