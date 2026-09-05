BEGIN;
SET LOCAL lock_timeout = '3s';
DROP INDEX IF EXISTS public.emergency_items_queue_open_created;
DROP INDEX IF EXISTS public.payments_store_created_id;
COMMIT;
