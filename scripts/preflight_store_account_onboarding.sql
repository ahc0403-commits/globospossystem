SET LOCAL transaction_read_only=on;
DO $$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['restaurants','brands','users','store_fixed_account_requirements','user_brand_access','user_store_access','user_tax_entity_access','legal_entity_fixed_account_requirements','procurement_role_roster','emergency_station_assignments'] LOOP
  IF to_regclass('public.'||t) IS NULL THEN RAISE EXCEPTION 'ONBOARDING_PREREQUISITE_MISSING:%',t; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM restaurants WHERE short_code IS NOT NULL GROUP BY upper(short_code) HAVING count(*)>1) THEN RAISE EXCEPTION 'DUPLICATE_STORE_ABBREVIATIONS'; END IF;
 IF to_regprocedure('public.connect_procurement_stores(uuid[])') IS NULL OR to_regprocedure('public.require_brand_admin_v1()') IS NULL THEN RAISE EXCEPTION 'ONBOARDING_CONTRACT_MISSING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM vault.decrypted_secrets WHERE name IN('cron_secret','app.settings.cron_secret')) THEN RAISE EXCEPTION 'ONBOARDING_CRON_SECRET_MISSING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='auth' AND indexname='users_instance_id_email_idx') THEN RAISE EXCEPTION 'ONBOARDING_AUTH_EMAIL_INDEX_MISSING'; END IF;
END $$;
SELECT 'ONBOARDING_PREFLIGHT_PASS' AS result;
