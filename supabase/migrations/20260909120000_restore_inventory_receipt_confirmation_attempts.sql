BEGIN;

-- production-gate: self-verifying

-- The verified staging baseline includes the receipt verification RPC but was
-- missing its idempotency/observability table from the earlier migration chain.
CREATE TABLE IF NOT EXISTS public.inventory_receipt_confirmation_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id uuid NOT NULL
    REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  receipt_id uuid NULL
    REFERENCES public.inventory_receipts(id) ON DELETE SET NULL,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  actor_id uuid NULL REFERENCES auth.users(id),
  attempt_key text NOT NULL,
  attempt_status text NOT NULL
    CHECK (attempt_status IN ('succeeded', 'replayed', 'noop')),
  requested_line_count integer NOT NULL DEFAULT 0,
  accepted_total_quantity_base numeric(12,3) NOT NULL DEFAULT 0,
  rejected_total_quantity_base numeric(12,3) NOT NULL DEFAULT 0,
  remaining_quantity_before_base numeric(12,3) NOT NULL DEFAULT 0,
  remaining_quantity_after_base numeric(12,3) NOT NULL DEFAULT 0,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, attempt_key)
);

CREATE INDEX IF NOT EXISTS idx_inventory_receipt_attempts_order_created
  ON public.inventory_receipt_confirmation_attempts (
    purchase_order_id,
    created_at DESC
  );

CREATE INDEX IF NOT EXISTS idx_inventory_receipt_attempts_store_created
  ON public.inventory_receipt_confirmation_attempts (
    restaurant_id,
    created_at DESC
  );

ALTER TABLE public.inventory_receipt_confirmation_attempts
  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts;

CREATE POLICY inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts
  FOR SELECT
  TO authenticated
  USING (
    auth.role() = 'service_role'
    OR public.can_access_inventory_purchase_store(restaurant_id)
  );

DO $verify$
BEGIN
  IF to_regclass('public.inventory_receipt_confirmation_attempts') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_CONFIRMATION_ATTEMPTS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint constraint_row
    JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = table_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND table_row.relname = 'inventory_receipt_confirmation_attempts'
      AND constraint_row.contype = 'u'
      AND pg_get_constraintdef(constraint_row.oid)
        LIKE '%purchase_order_id, attempt_key%'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_ATTEMPT_IDEMPOTENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class table_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = table_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND table_row.relname = 'inventory_receipt_confirmation_attempts'
      AND table_row.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_ATTEMPT_RLS_DISABLED';
  END IF;
END;
$verify$;

COMMIT;
