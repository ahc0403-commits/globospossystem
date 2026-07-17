BEGIN;

-- This feature creates only one RPC. Existing QR tokens and the explicit
-- rotation RPC are intentionally left untouched.
DROP FUNCTION IF EXISTS public.admin_get_or_create_table_qrs(uuid, uuid[]);

COMMIT;

SELECT 'TABLE_QR_BATCH_ROLLBACK_OK' AS result;
