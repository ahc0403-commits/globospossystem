-- production-gate: self-verifying
-- Recompute after the preceding statement has expired Office principals.
-- now() is the transaction start and can precede their clock_timestamp expiry.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
SET LOCAL search_path='';
DO $migration$
DECLARE definition text; previous_owner oid; previous_acl aclitem[];
BEGIN
  SELECT pg_get_functiondef(p.oid),p.proowner,p.proacl INTO definition,previous_owner,previous_acl
    FROM pg_proc p WHERE p.oid='public.connect_procurement_stores(uuid[])'::regprocedure;
  IF encode(sha256(convert_to(definition,'UTF8')),'hex')<>
      'ad1acdc2880bec2f3797080c259179bb72e75f74cd84a57577710cc130df044a'
    OR (length(definition)-length(replace(definition,'now()','')))/5<>8
    OR (length(definition)-length(replace(definition,E'\nBEGIN\n','')))/7<>1 THEN
    RAISE EXCEPTION 'PROCUREMENT_READINESS_DEFINITION_UNREVIEWED'; END IF;
  definition:=replace(definition,E'\nBEGIN\n',
    E'\nDECLARE v_readiness_observed_at timestamptz := clock_timestamp();\nBEGIN\n');
  definition:=replace(definition,'now()','v_readiness_observed_at');
  EXECUTE definition;
  IF EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.connect_procurement_stores(uuid[])'::regprocedure
    AND (p.proowner IS DISTINCT FROM previous_owner OR p.proacl IS DISTINCT FROM previous_acl
      OR position('v_readiness_observed_at' IN p.prosrc)=0 OR position('now()' IN p.prosrc)>0)) THEN
    RAISE EXCEPTION 'PROCUREMENT_READINESS_CONTRACT_DRIFT'; END IF;
END $migration$;
COMMIT;
