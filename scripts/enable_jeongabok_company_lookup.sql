-- Authorized operational feature setting, not a schema/function deployment.
-- Existing POS clients and Edge already support this gate.
-- Inspect the returned previous value and retain it before any rollback.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='10s';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.restaurants
    WHERE id='273b057e-3b69-46e3-93c1-6194c2802849'
      AND name='JeonGabok Binh Thanh' AND is_active)
    THEN RAISE EXCEPTION 'JEONGABOK_LOOKUP_TARGET_DRIFT'; END IF;
END; $$;
WITH previous AS MATERIALIZED (
  SELECT r.id,s.enabled,(s.store_id IS NOT NULL) AS setting_existed
  FROM public.restaurants r LEFT JOIN public.company_tax_lookup_settings s ON s.store_id=r.id
  WHERE r.id='273b057e-3b69-46e3-93c1-6194c2802849' FOR UPDATE OF r
), changed AS (
  INSERT INTO public.company_tax_lookup_settings(store_id,enabled)
  SELECT id,true FROM previous
  ON CONFLICT(store_id) DO UPDATE SET enabled=EXCLUDED.enabled
  RETURNING store_id,enabled
)
SELECT changed.store_id,previous.setting_existed,previous.enabled AS previous_enabled,
  changed.enabled,clock_timestamp() AS changed_at
FROM changed JOIN previous ON previous.id=changed.store_id;
COMMIT;
