-- ============================================================
-- QSC v2 Wave 6: Office read-model wrapper views
-- 2026-05-07
-- Scope:
-- - add Office-facing wrapper views on top of POS QSC read models
-- - preserve physical restaurants / restaurant_id invariants
-- - keep Office bridge consumption additive and read-only
-- Notes:
-- - intended to run after Wave 3 monitoring views
-- - no Office app code change is required by this migration alone
-- ============================================================

-- ------------------------------------------------------------
-- v_office_qsc_dashboard
-- Latest store snapshot for Office dashboard cards and store list.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_office_qsc_dashboard AS
SELECT
  ds.store_id AS restaurant_id,
  ds.store_id,
  ds.brand_id,
  ds.store_name,
  ds.latest_check_date,
  ds.total_checks,
  ds.submitted_checks,
  ds.pending_checks,
  ds.overdue_checks,
  ds.failed_checks,
  ds.missing_photo_checks,
  ds.pending_sv_reviews,
  ds.open_followups,
  ds.average_score,
  ds.completion_rate,
  CASE
    WHEN ds.latest_check_date IS NULL THEN 'no_data'
    WHEN COALESCE(ds.overdue_checks, 0) > 0
       OR COALESCE(ds.failed_checks, 0) > 0
       OR COALESCE(ds.open_followups, 0) > 0 THEN 'risk'
    WHEN COALESCE(ds.pending_checks, 0) > 0
       OR COALESCE(ds.missing_photo_checks, 0) > 0
       OR COALESCE(ds.pending_sv_reviews, 0) > 0 THEN 'caution'
    ELSE 'good'
  END AS store_status
FROM public.v_qsc_dashboard_summary ds;

COMMENT ON VIEW public.v_office_qsc_dashboard IS
  'Office-facing wrapper over v_qsc_dashboard_summary with both restaurant_id and store_id aliases.';

-- ------------------------------------------------------------
-- v_office_qsc_store_latest
-- Latest per-store daily rollup for Office quality store tables.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_office_qsc_store_latest AS
WITH latest_dates AS (
  SELECT
    store_id,
    MAX(check_date) AS latest_check_date
  FROM public.v_qsc_store_status
  GROUP BY store_id
)
SELECT
  ss.store_id AS restaurant_id,
  ss.store_id,
  ss.brand_id,
  ss.store_name,
  ss.check_date,
  ss.total_checks,
  ss.submitted_checks,
  ss.pending_checks,
  ss.overdue_checks,
  ss.pass_checks,
  ss.fail_checks,
  ss.na_checks,
  ss.missing_photo_checks,
  ss.partial_photo_checks,
  ss.pending_sv_reviews,
  ss.active_followups,
  ss.average_score,
  ss.average_sv_score,
  ss.completion_rate,
  ss.store_status
FROM public.v_qsc_store_status ss
JOIN latest_dates ld
  ON ld.store_id = ss.store_id
 AND ld.latest_check_date = ss.check_date;

COMMENT ON VIEW public.v_office_qsc_store_latest IS
  'Office-facing latest daily store rollup for QSC monitoring and problem-store lists.';

-- ------------------------------------------------------------
-- v_office_qsc_issue_queue
-- Problem-only queue for Office review, issue creation, and follow-up.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_office_qsc_issue_queue AS
SELECT
  vm.check_id,
  vm.store_id AS restaurant_id,
  vm.store_id,
  vm.brand_id,
  vm.store_name,
  vm.category,
  vm.qsc_domain,
  vm.criteria_text,
  vm.check_date,
  vm.result,
  vm.photo_status,
  vm.submission_status,
  vm.sv_review_status,
  vm.followup_status,
  CASE
    WHEN vm.submission_status = 'overdue'
         OR (vm.result = 'fail' AND vm.photo_status = 'missing') THEN 'critical'
    WHEN vm.result = 'fail'
         OR vm.sv_review_status = 'rejected' THEN 'high'
    WHEN vm.sv_review_status = 'pending'
         OR vm.photo_status IN ('missing', 'partial') THEN 'medium'
    WHEN vm.submission_status = 'pending'
         OR vm.followup_status IN ('open', 'in_progress') THEN 'low'
    ELSE 'info'
  END AS severity,
  vm.evidence_photo_url,
  vm.note,
  vm.checked_by,
  vm.created_at,
  vm.submitted_at,
  vm.score,
  vm.grade
FROM public.v_quality_monitoring vm
WHERE vm.submission_status IN ('pending', 'overdue')
   OR vm.result = 'fail'
   OR vm.photo_status IN ('missing', 'partial')
   OR vm.sv_review_status IN ('pending', 'rejected')
   OR vm.followup_status IN ('open', 'in_progress');

COMMENT ON VIEW public.v_office_qsc_issue_queue IS
  'Office-facing issue queue wrapper over v_quality_monitoring for evidence review and follow-up creation.';

GRANT SELECT ON public.v_office_qsc_dashboard TO authenticated;
GRANT SELECT ON public.v_office_qsc_store_latest TO authenticated;
GRANT SELECT ON public.v_office_qsc_issue_queue TO authenticated;
