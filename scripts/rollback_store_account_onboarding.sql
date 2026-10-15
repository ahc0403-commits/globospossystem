-- Emergency feature stop. Preserve stores, issued accounts, access grants,
-- abbreviations and job history. Apply only through an explicitly authorized
-- incident procedure; rollback does not revoke staff access or delete identities.
BEGIN;
SELECT cron.unschedule('store-account-onboarding');
REVOKE EXECUTE ON FUNCTION public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.claim_store_onboarding_v1(uuid),public.finish_store_onboarding_v1(uuid,uuid) FROM service_role;
COMMIT;
