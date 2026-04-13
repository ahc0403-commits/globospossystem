-- ============================================================================
-- MANUAL ROLLBACK ONLY: revert expand alias objects from 20260412140000
-- Do not include this file in normal migration chain execution.
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS public.public_store_profiles;
DROP VIEW IF EXISTS public.stores;
DROP FUNCTION IF EXISTS public.get_user_store_id();

COMMIT;
