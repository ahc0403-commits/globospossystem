\set ON_ERROR_STOP on

-- Logical rollback only. It stops new paperless routing without deleting
-- receipts, links, audit history, or in-flight KDS work. Existing paperless
-- orders remain visible until their captured work drains.
BEGIN;

WITH changed AS (
  UPDATE public.restaurant_settings
  SET fulfillment_mode = 'pos_print', updated_at = now()
  WHERE fulfillment_mode = 'paperless'
  RETURNING restaurant_id
)
INSERT INTO public.audit_logs (
  actor_id, action, entity_type, entity_id, details
)
SELECT
  auth.uid(),
  'rollback_fulfillment_mode',
  'restaurants',
  changed.restaurant_id,
  jsonb_build_object(
    'next_mode', 'pos_print',
    'strategy', 'logical_preserve_receipts_and_drain_kds'
  )
FROM changed;

COMMIT;

SELECT 'PAPERLESS_RECEIPT_LOGICAL_ROLLBACK_OK' AS result;
