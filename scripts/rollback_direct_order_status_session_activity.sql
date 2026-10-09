-- Emergency rollback only: restores the original status-read failure.
-- Function body, ownership, privileges and all business records are retained.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
DO $rollback$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc
    WHERE oid = 'public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure
      AND md5(prosrc) = '742d56d41d4b2520149a95c5b64074b9') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STATUS_SESSION_ACTIVITY_ROLLBACK_ANCHOR_DRIFT';
  END IF;
  ALTER FUNCTION public.direct_order_public_status_v5(uuid,text,uuid) STABLE;
END;
$rollback$;
NOTIFY pgrst, 'reload schema';
COMMIT;
