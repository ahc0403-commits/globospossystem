BEGIN;

-- Public QR ordering must enter through token-backed SECURITY DEFINER RPCs.
-- Direct anonymous table writes bypass the QR idempotency and table-token
-- guards even when RLS blocks runtime mutation, so remove the table grant.
REVOKE ALL ON TABLE public.orders FROM PUBLIC, anon;

COMMIT;
