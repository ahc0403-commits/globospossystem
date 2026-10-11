-- Reviewed atomic release of recipient delivery, POS buyers/ledger, ESGOO,
-- and the authorized data-access improvements. Individual source migrations
-- remain reviewable; apply this bundle once through deploy_pos_production.sh.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE pos_release_anchors ON COMMIT DROP AS
 SELECT md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)) AS payment,
 (SELECT md5(COALESCE(string_agg(to_jsonb(f)::text,'' ORDER BY f.request_id),'')) FROM public.direct_order_financials f) AS financials,
 (SELECT md5(COALESCE(string_agg(snapshot::text,'' ORDER BY id),'')) FROM public.digital_receipts) AS issued_receipts;

