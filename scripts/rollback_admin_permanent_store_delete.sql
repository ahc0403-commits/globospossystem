\set ON_ERROR_STOP on

-- This rollback removes the callable API only. The reviewed one-time deletion
-- is intentionally irreversible and cannot be reconstructed from this script.
DROP FUNCTION IF EXISTS public.admin_purge_inactive_store(uuid, text);
DROP FUNCTION IF EXISTS public._purge_inactive_store_data(uuid, text, uuid);

SELECT 'ADMIN_STORE_PURGE_FUNCTIONS_ROLLED_BACK' AS result;
