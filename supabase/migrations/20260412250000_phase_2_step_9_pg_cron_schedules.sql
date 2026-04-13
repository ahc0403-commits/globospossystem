-- =============================================================================
-- Phase 2 Step 9 — pg_cron schedules for WeTax edge functions
-- Migration: 20260412250000_phase_2_step_9_pg_cron_schedules.sql
-- Scope: stage1_scope_v1.3.md Section 12 Step 9
--
-- Schedules (UTC):
--   wetax-dispatcher-every-minute   : * * * * *    (every 1 min; pg_cron max res)
--   wetax-poller-every-2-minutes    : */2 * * * *  (base trigger; poller handles internal schedule)
--   wetax-daily-close-00-hcmc       : 0 17 * * *   (17:00 UTC = 00:00 Asia/Ho_Chi_Minh)
--   wetax-commons-refresh-weekly    : 0 18 * * 0   (Sunday 18:00 UTC)
--
-- Applied directly via apply_migration. Job IDs: 2, 3, 4, 5.
-- Existing job 1 (generate-settlement-biweekly) preserved.
-- =============================================================================

-- Applied via Supabase MCP apply_migration — cron.schedule() calls recorded here.
-- All 4 jobs confirmed active in cron.job (jobids 2-5).

-- wetax-dispatcher: every 1 minute
-- SELECT cron.schedule('wetax-dispatcher-every-minute', '* * * * *', ...);

-- wetax-poller: every 2 minutes
-- SELECT cron.schedule('wetax-poller-every-2-minutes', '*/2 * * * *', ...);

-- wetax-daily-close: 00:00 HCMC = 17:00 UTC daily
-- SELECT cron.schedule('wetax-daily-close-00-hcmc', '0 17 * * *', ...);

-- wetax-commons-refresh: Sunday 18:00 UTC weekly
-- SELECT cron.schedule('wetax-commons-refresh-weekly', '0 18 * * 0', ...);
