-- Rotate CRON_SECRET: replace hardcoded bearer tokens in cron job commands
-- with a runtime lookup from Supabase Vault (vault.decrypted_secrets).
--
-- Deployment sequence (zero-gap cutover):
--   1. Set new CRON_SECRET in edge function env (Supabase dashboard → Functions → Secrets)
--   2. Insert the SAME new secret into Vault (the INSERT below, or via dashboard)
--   3. Apply this migration (rewrites cron job commands to read from Vault)
--   4. Verify next cron tick succeeds (check cron.job_run_details)
--   5. Old hardcoded value is now dead — no rollback to it, only forward to a new rotation
--
-- The edge functions already read CRON_SECRET from Deno.env.get("CRON_SECRET"),
-- so no edge function code changes are needed.

-- Step 1: Store the new CRON_SECRET in Vault.
-- IMPORTANT: Replace 'REPLACE_WITH_NEW_SECRET' with the actual new secret value
-- when executing. This placeholder ensures no real secret is committed to git.
-- In practice, run this via Supabase SQL Editor with the real value, NOT via migration push.
--
-- INSERT INTO vault.secrets (name, secret, description)
-- VALUES ('cron_secret', 'REPLACE_WITH_NEW_SECRET', 'Bearer token for pg_cron → edge function auth')
-- ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;

-- Step 2: Reschedule all cron jobs to read the bearer token from Vault at runtime.
-- Using cron.alter_job is not available in all pg_cron versions, so we unschedule + reschedule.

DO $$
DECLARE
  v_base_url TEXT := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/';
BEGIN
  -- Remove old schedules (silently skip if not found)
  PERFORM cron.unschedule('wetax-dispatcher-every-minute');
  PERFORM cron.unschedule('wetax-poller-every-2-minutes');
  PERFORM cron.unschedule('wetax-daily-close-00-hcmc');
  PERFORM cron.unschedule('wetax-commons-refresh-weekly');

  -- Reschedule with Vault-based secret lookup
  PERFORM cron.schedule(
    'wetax-dispatcher-every-minute',
    '* * * * *',
    format($cmd$
    SELECT net.http_post(
      url     := %L || 'wetax-dispatcher',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'cron_secret' LIMIT 1),
        'Content-Type',  'application/json'
      ),
      body    := '{}'::jsonb
    );
    $cmd$, v_base_url)
  );

  PERFORM cron.schedule(
    'wetax-poller-every-2-minutes',
    '*/2 * * * *',
    format($cmd$
    SELECT net.http_post(
      url     := %L || 'wetax-poller',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'cron_secret' LIMIT 1),
        'Content-Type',  'application/json'
      ),
      body    := '{}'::jsonb
    );
    $cmd$, v_base_url)
  );

  PERFORM cron.schedule(
    'wetax-daily-close-00-hcmc',
    '0 17 * * *',
    format($cmd$
    SELECT net.http_post(
      url     := %L || 'wetax-daily-close',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'cron_secret' LIMIT 1),
        'Content-Type',  'application/json'
      ),
      body    := '{}'::jsonb
    );
    $cmd$, v_base_url)
  );

  PERFORM cron.schedule(
    'wetax-commons-refresh-weekly',
    '0 18 * * 0',
    format($cmd$
    SELECT net.http_post(
      url     := %L || 'wetax-onboarding',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'cron_secret' LIMIT 1),
        'Content-Type',  'application/json'
      ),
      body    := '{"operation":"commons_refresh"}'::jsonb
    );
    $cmd$, v_base_url)
  );
END $$;

-- Verification queries (run manually after applying):
--
-- 1. Confirm no hardcoded secret remains in cron commands:
-- SELECT jobname, command FROM cron.job WHERE command LIKE '%8689bac6%';
-- Expected: 0 rows
--
-- 2. Confirm all 4 jobs exist with vault lookup:
-- SELECT jobname, schedule, command LIKE '%vault.decrypted_secrets%' AS uses_vault
-- FROM cron.job
-- WHERE jobname IN (
--   'wetax-dispatcher-every-minute',
--   'wetax-poller-every-2-minutes',
--   'wetax-daily-close-00-hcmc',
--   'wetax-commons-refresh-weekly'
-- );
-- Expected: 4 rows, all uses_vault = true
--
-- 3. Confirm next tick succeeds (wait 2 minutes, then):
-- SELECT jobname, status, return_message, start_time
-- FROM cron.job_run_details
-- WHERE start_time > NOW() - INTERVAL '5 minutes'
-- ORDER BY start_time DESC;
