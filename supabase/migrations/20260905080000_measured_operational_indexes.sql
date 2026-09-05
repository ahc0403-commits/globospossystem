BEGIN;
-- Small measured production relations. Fail promptly instead of waiting behind
-- a busy writer; the production wrapper applies this migration atomically.
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
-- KDS snapshot/completed lookups correlate by queue_id and exclude cancelled
-- items. Existing (session_id, order_id) cannot restrict these queue reads.
CREATE INDEX IF NOT EXISTS emergency_items_queue_open_created
  ON public.emergency_fulfillment_items (queue_id, created_at, order_item_id)
  WHERE is_cancelled = false;
-- Financial inputs/reports restrict one store and a half-open date range;
-- keyset pages also order by created_at,id. Keep both revenue and service rows.
CREATE INDEX IF NOT EXISTS payments_store_created_id
  ON public.payments (restaurant_id, created_at, id);
COMMIT;
