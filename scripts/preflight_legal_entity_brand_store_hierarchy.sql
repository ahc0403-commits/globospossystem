-- Forward-only preflight for POS production. This file performs no mutations.
DO $preflight$
DECLARE
  v_photo_candidates integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.brands') IS NULL
     OR to_regclass('public.tax_entity') IS NULL
     OR to_regclass('public.store_tax_entity_history') IS NULL
     OR to_regclass('public.meinvoice_tax_entity_config') IS NULL THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_REQUIRED_POS_TABLE_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('store_id'), ('tax_entity_id'), ('effective_from'), ('effective_to'),
      ('reason'), ('created_at'), ('created_by')
    ) required(column_name)
    WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = 'store_tax_entity_history'
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_HISTORY_SCHEMA_MISMATCH';
  END IF;

  IF to_regprocedure(
    'public.admin_create_restaurant(text,text,text,text,numeric,uuid,text,uuid)'
  ) IS NULL OR to_regprocedure(
    'public.admin_update_restaurant(uuid,text,text,text,text,numeric,uuid,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_LEGACY_RPC_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tax_entity
    WHERE id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_AKJ_ID_CONFLICT';
  END IF;

  SELECT count(*) INTO v_photo_candidates
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND te.tax_code = 'PLACEHOLDER_DEV_000';

  IF v_photo_candidates <> 7 THEN
    RAISE EXCEPTION
      'HIERARCHY_PREFLIGHT_PHOTO_CANDIDATE_COUNT expected=7 actual=%',
      v_photo_candidates;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants r
    JOIN public.tax_entity te ON te.id = r.tax_entity_id
    JOIN public.store_tax_entity_history h
      ON h.store_id = r.id AND h.effective_to IS NULL
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND te.tax_code = 'PLACEHOLDER_DEV_000'
      AND h.tax_entity_id <> r.tax_entity_id
  ) THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_PHOTO_ACTIVE_HISTORY_MISMATCH';
  END IF;

  IF to_regclass('public.tax_entity_brands') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_backup_state') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_photo_backup') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_history_backup') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_object_backup') IS NOT NULL THEN
    RAISE EXCEPTION 'HIERARCHY_PREFLIGHT_MIGRATION_ARTIFACT_ALREADY_PRESENT';
  END IF;
END;
$preflight$;

SELECT 'hierarchy preflight passed' AS result;
