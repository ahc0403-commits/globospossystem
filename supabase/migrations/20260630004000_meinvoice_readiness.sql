-- Read-only MISA meInvoice readiness summary for POS admins.
-- No credentials are exposed and no dispatch is triggered.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_meinvoice_readiness()
RETURNS TABLE (
  tax_entity_id uuid,
  tax_code text,
  seller_name text,
  integration_status text,
  app_id_configured boolean,
  invoice_series_configured boolean,
  dispatch_enabled boolean,
  active_store_count int,
  pending_manual_config_count int,
  dispatch_paused_count int,
  failed_count int,
  ready_to_dispatch boolean,
  blocking_reasons text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_dispatch_enabled boolean;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'MEINVOICE_READINESS_FORBIDDEN';
  END IF;

  SELECT COALESCE((
    SELECT value = 'true'
    FROM public.system_config
    WHERE key = 'meinvoice_dispatch_enabled'
  ), false)
  INTO v_dispatch_enabled;

  RETURN QUERY
  WITH accessible_tax_entities AS (
    SELECT
      te.id AS tax_entity_id,
      te.tax_code,
      te.name AS seller_name,
      COALESCE(cfg.integration_status, 'needs_vendor_activation') AS integration_status,
      COALESCE(NULLIF(trim(cfg.app_id), ''), '') <> '' AS app_id_configured,
      COALESCE(NULLIF(trim(cfg.invoice_series), ''), '') <> '' AS invoice_series_configured,
      count(DISTINCT r.id)::int AS active_store_count
    FROM public.tax_entity te
    JOIN public.restaurants r
      ON r.tax_entity_id = te.id
    LEFT JOIN public.meinvoice_tax_entity_config cfg
      ON cfg.tax_entity_id = te.id
    WHERE te.einvoice_provider = 'meinvoice'
      AND te.tax_code <> 'PLACEHOLDER_DEV_000'
      AND COALESCE(r.is_active, true) = true
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = r.id
        )
      )
    GROUP BY
      te.id,
      te.tax_code,
      te.name,
      cfg.integration_status,
      cfg.app_id,
      cfg.invoice_series
  ),
  job_counts AS (
    SELECT
      mj.tax_entity_id,
      count(*) FILTER (WHERE mj.status = 'pending_manual_config')::int
        AS pending_manual_config_count,
      count(*) FILTER (WHERE mj.status = 'dispatch_paused')::int
        AS dispatch_paused_count,
      count(*) FILTER (WHERE mj.status IN ('failed', 'manual_action_required'))::int
        AS failed_count
    FROM public.meinvoice_jobs mj
    JOIN accessible_tax_entities ate
      ON ate.tax_entity_id = mj.tax_entity_id
    GROUP BY mj.tax_entity_id
  )
  SELECT
    ate.tax_entity_id,
    ate.tax_code,
    ate.seller_name,
    ate.integration_status,
    ate.app_id_configured,
    ate.invoice_series_configured,
    v_dispatch_enabled AS dispatch_enabled,
    ate.active_store_count,
    COALESCE(jc.pending_manual_config_count, 0) AS pending_manual_config_count,
    COALESCE(jc.dispatch_paused_count, 0) AS dispatch_paused_count,
    COALESCE(jc.failed_count, 0) AS failed_count,
    (
      v_dispatch_enabled
      AND ate.integration_status = 'active'
      AND ate.app_id_configured
      AND ate.invoice_series_configured
    ) AS ready_to_dispatch,
    array_remove(ARRAY[
      CASE WHEN NOT v_dispatch_enabled THEN 'dispatch_disabled' END,
      CASE WHEN ate.integration_status <> 'active' THEN 'integration_not_active' END,
      CASE WHEN NOT ate.app_id_configured THEN 'app_id_missing' END,
      CASE WHEN NOT ate.invoice_series_configured THEN 'invoice_series_missing' END
    ], NULL)::text[] AS blocking_reasons
  FROM accessible_tax_entities ate
  LEFT JOIN job_counts jc
    ON jc.tax_entity_id = ate.tax_entity_id
  ORDER BY ate.seller_name, ate.tax_code;
END;
$$;

COMMENT ON FUNCTION public.get_meinvoice_readiness() IS
  'Read-only MISA readiness summary for accessible tax entities. Does not expose credentials or trigger dispatch.';

GRANT EXECUTE ON FUNCTION public.get_meinvoice_readiness() TO authenticated;

COMMIT;
