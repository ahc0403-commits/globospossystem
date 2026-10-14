DO $$ BEGIN
 IF to_regprocedure('public.procurement_approval_inbox_batch(jsonb,jsonb)') IS NULL
 OR to_regclass('public.store_fixed_account_requirements') IS NULL
 OR to_regclass('public.procurement_store_onboarding') IS NOT NULL
 THEN RAISE EXCEPTION 'PROCUREMENT_ONBOARDING_PRECONDITION_FAILED'; END IF;
END $$;
