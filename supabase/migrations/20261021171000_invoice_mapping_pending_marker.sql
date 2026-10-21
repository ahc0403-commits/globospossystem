-- The existing invoice-mapping trigger writes this pre-issue hold marker.
-- Without it, the enqueue subtransaction rolls back and leaves no retry job.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
ALTER TABLE public.meinvoice_jobs DROP CONSTRAINT meinvoice_jobs_manual_action_type_check;
ALTER TABLE public.meinvoice_jobs ADD CONSTRAINT meinvoice_jobs_manual_action_type_check
 CHECK(manual_action_type IS NULL OR manual_action_type IN (
  'buyer_info_after_issue','replace','adjust','incorrect_invoice_notice',
  'misa_portal_review','invoice_mapping_required')) NOT VALID;
ALTER TABLE public.meinvoice_jobs VALIDATE CONSTRAINT meinvoice_jobs_manual_action_type_check;
DO $$ BEGIN
 IF position('invoice_mapping_required' IN pg_get_constraintdef((SELECT oid FROM pg_constraint
  WHERE conrelid='public.meinvoice_jobs'::regclass AND conname='meinvoice_jobs_manual_action_type_check')))=0
 THEN RAISE EXCEPTION 'INVOICE_MAPPING_HOLD_MARKER_MISSING'; END IF;
END $$;
COMMIT;
