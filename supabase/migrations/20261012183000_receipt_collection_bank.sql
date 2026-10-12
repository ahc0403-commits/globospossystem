BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout = '3s';

-- Add the beneficiary to the receipt's existing profile lookup. The print
-- agent consumes the queued snapshot without an RPC for each print job.
DO $patch$
DECLARE
  definition text;
BEGIN
  SELECT pg_get_functiondef('public.enrich_cashier_receipt_payload()'::regprocedure)
  INTO definition;
  IF strpos(definition, 'AS collection_bank') > 0 THEN
    RETURN;
  END IF;
  IF strpos(definition, E'    r.address\n  INTO v_profile') = 0
    OR strpos(definition, E'  LEFT JOIN public.tax_entity te ON te.id = r.tax_entity_id\n') = 0
    OR strpos(definition, E'    ''legal_name'', v_profile.legal_name,') = 0 THEN
    RAISE EXCEPTION 'RECEIPT_COLLECTION_BANK_ANCHOR_CHANGED';
  END IF;
  definition := replace(definition, E'    r.address\n  INTO v_profile',
    E'    r.address,\n    CASE WHEN collection.id IS NULL THEN NULL ELSE jsonb_build_object(\n      ''id'', collection.id, ''bin'', collection.bank_bin,\n      ''label'', collection.bank_label, ''account_number'', collection.account_number,\n      ''account_holder'', collection.account_holder\n    ) END AS collection_bank\n  INTO v_profile');
  definition := replace(definition,
    E'  LEFT JOIN public.tax_entity te ON te.id = r.tax_entity_id\n',
    E'  LEFT JOIN public.tax_entity te ON te.id = r.tax_entity_id\n  LEFT JOIN public.tax_entity_collection_accounts collection\n    ON collection.tax_entity_id = r.tax_entity_id\n    AND collection.retired_at IS NULL AND collection.effective_from <= now()\n');
  definition := replace(definition, E'    ''legal_name'', v_profile.legal_name,',
    E'    ''legal_name'', v_profile.legal_name,\n    ''bank'', CASE WHEN TG_OP = ''UPDATE'' AND NULLIF(OLD.payload->''bank'', ''null''::jsonb) IS NOT NULL\n      THEN OLD.payload->''bank'' ELSE v_profile.collection_bank END,');
  -- A store's legal entity determines both the beneficiary and seller identity.
  -- The same brand can operate stores belonging to different legal entities.
  definition := replace(definition,
    E'    CASE WHEN lower(COALESCE(b.name, r.name)) LIKE ''%bunsik%''\n      THEN ''CÔNG TY TNHH AKJ INTERNATIONAL'' ELSE te.name END AS legal_name,',
    E'    te.name AS legal_name,');
  definition := replace(definition,
    E'    CASE WHEN lower(COALESCE(b.name, r.name)) LIKE ''%bunsik%''\n      THEN ''0318453298'' ELSE NULLIF(te.tax_code, ''PLACEHOLDER_DEV_000'') END AS tax_code,',
    E'    NULLIF(te.tax_code, ''PLACEHOLDER_DEV_000'') AS tax_code,');
  EXECUTE definition;
END $patch$;

DO $verify$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('public.enrich_cashier_receipt_payload()'::regprocedure)
  INTO definition;
  IF strpos(definition, 'AS collection_bank') = 0
    OR strpos(definition, 'LEFT JOIN public.tax_entity_collection_accounts collection') = 0
    OR strpos(definition, 'THEN OLD.payload->''bank'' ELSE v_profile.collection_bank END') = 0
    OR strpos(definition, 'te.name AS legal_name') = 0
    OR strpos(definition, 'THEN ''0318453298''') > 0
    OR NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.print_jobs'::regclass
        AND tgname = 'enrich_cashier_receipt_payload_trigger' AND NOT tgisinternal
    ) THEN
    RAISE EXCEPTION 'RECEIPT_COLLECTION_BANK_CONTRACT_DRIFT';
  END IF;
END $verify$;
COMMIT;
