-- Phase 2 Step 9 — pg_cron schedules for WeTax edge functions
-- Scope: stage1_scope_v1.3.md Section 12 Step 9
--
-- Schedules (all UTC):
--   wetax-dispatcher  : every 1 min  (* * * * *)
--                       pg_cron minimum is 1 min; scope says 30s but not achievable
--   wetax-poller      : every 2 min  (*/2 * * * *)
--                       poller handles exponential internal schedule; base trigger only
--   wetax-daily-close : daily 17:00 UTC = 00:00 Asia/Ho_Chi_Minh  (0 17 * * *)
--   wetax-commons-refresh: weekly Sunday 18:00 UTC  (0 18 * * 0)
--                          via wetax-onboarding commons_refresh operation
--
-- CRON_SECRET: same value as generate-settlement-biweekly (established pattern)
-- Edge function URL base: https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'wetax-dispatcher-every-minute',
      '* * * * *',
      $inner$
      SELECT net.http_post(
        url     := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/wetax-dispatcher',
        headers := jsonb_build_object(
          'Authorization', 'Bearer 8689bac6bbae94e5e281dbf98e55a1ce83709cf987c34efb1a68c2dfc4831577',
          'Content-Type',  'application/json'
        ),
        body    := '{}'::jsonb
      );
      $inner$
    );

    PERFORM cron.schedule(
      'wetax-poller-every-2-minutes',
      '*/2 * * * *',
      $inner$
      SELECT net.http_post(
        url     := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/wetax-poller',
        headers := jsonb_build_object(
          'Authorization', 'Bearer 8689bac6bbae94e5e281dbf98e55a1ce83709cf987c34efb1a68c2dfc4831577',
          'Content-Type',  'application/json'
        ),
        body    := '{}'::jsonb
      );
      $inner$
    );

    PERFORM cron.schedule(
      'wetax-daily-close-00-hcmc',
      '0 17 * * *',
      $inner$
      SELECT net.http_post(
        url     := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/wetax-daily-close',
        headers := jsonb_build_object(
          'Authorization', 'Bearer 8689bac6bbae94e5e281dbf98e55a1ce83709cf987c34efb1a68c2dfc4831577',
          'Content-Type',  'application/json'
        ),
        body    := '{}'::jsonb
      );
      $inner$
    );

    PERFORM cron.schedule(
      'wetax-commons-refresh-weekly',
      '0 18 * * 0',
      $inner$
      SELECT net.http_post(
        url     := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/wetax-onboarding',
        headers := jsonb_build_object(
          'Authorization', 'Bearer 8689bac6bbae94e5e281dbf98e55a1ce83709cf987c34efb1a68c2dfc4831577',
          'Content-Type',  'application/json'
        ),
        body    := '{"operation":"commons_refresh"}'::jsonb
      );
      $inner$
    );
  ELSE
    RAISE NOTICE 'pg_cron extension unavailable; skipping WeTax cron schedule registration.';
  END IF;
END
$$;;
