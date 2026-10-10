BEGIN READ ONLY;
DO $preflight$
BEGIN
 IF to_regprocedure('public.direct_order_public_status_v6(uuid,text,uuid)') IS NULL
 OR to_regprocedure('public.direct_order_staff_list_before_reconciliation(uuid,text[],integer,text)') IS NULL
 OR to_regclass('public.direct_order_translation_jobs') IS NOT NULL THEN RAISE EXCEPTION 'TRANSLATION_PREDECESSOR_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron' AND extversion>='1.6')
 OR NOT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_net')
 OR NOT EXISTS(SELECT 1 FROM vault.decrypted_secrets WHERE name IN ('cron_secret','app.settings.cron_secret') AND length(decrypted_secret)>=16) THEN RAISE EXCEPTION 'TRANSLATION_SCHEDULER_NOT_READY'; END IF;
END; $preflight$;
COMMIT;
