-- Read-only/dry-run inventory. This deliberately emits aggregate counts only;
-- it never selects proof_photo_url or Storage object names.
BEGIN TRANSACTION READ ONLY;

SELECT
  count(*) FILTER (
    WHERE NULLIF(btrim(proof_photo_url), '') IS NOT NULL
  ) AS legacy_url_rows,
  count(*) FILTER (
    WHERE NULLIF(btrim(proof_photo_url), '') IS NOT NULL
      AND NULLIF(btrim(proof_object_path), '') IS NULL
  ) AS legacy_url_rows_without_object_path,
  count(*) FILTER (
    WHERE NULLIF(btrim(proof_photo_url), '') IS NOT NULL
      AND proof_photo_url !~ '^https://[a-z0-9-]+\.supabase\.co/'
  ) AS unexpected_legacy_url_shape_rows,
  count(*) FILTER (
    WHERE NULLIF(btrim(proof_object_path), '') IS NOT NULL
      AND proof_object_path !~ '^[^/]+/[0-9a-f-]+/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f-]+\.jpg$'
  ) AS unexpected_object_path_shape_rows,
  min(created_at) FILTER (
    WHERE NULLIF(btrim(proof_photo_url), '') IS NOT NULL
  ) AS oldest_legacy_row_created_at,
  max(created_at) FILTER (
    WHERE NULLIF(btrim(proof_photo_url), '') IS NOT NULL
  ) AS newest_legacy_row_created_at
FROM public.payments;

ROLLBACK;
