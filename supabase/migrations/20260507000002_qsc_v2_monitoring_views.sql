-- ============================================================
-- QSC v2 Wave 3: monitoring view expansion
-- 2026-05-07
-- Scope:
-- - extend v_quality_monitoring without breaking existing readers
-- - add QSC-oriented summary views for dashboard/store/item read paths
-- - keep Office bridge compatibility by preserving legacy columns first
-- Notes:
-- - intended to run after Wave 1 additive columns
-- - qc_followups remains the source for improvement tracking in POS
-- - direct stores only, consistent with current Office monitoring contract
-- ============================================================

-- ------------------------------------------------------------
-- v_quality_monitoring
-- Preserve legacy columns in-place, append QSC v2 fields afterwards.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_quality_monitoring AS
WITH qsc_source AS (
  SELECT
    qc.id AS check_id,
    qc.restaurant_id AS store_id,
    r.brand_id,
    r.name AS store_name,
    qt.id AS template_id,
    qt.category,
    qt.criteria_text,
    qc.check_date,
    qc.result,
    qc.evidence_photo_url,
    qc.note,
    qc.checked_by,
    qc.created_at,
    qt.qsc_domain,
    COALESCE(qt.requires_photo, TRUE) AS requires_photo,
    COALESCE(qc.photo_required_count, qt.required_photo_count, 0) AS required_photo_count,
    COALESCE(qc.photo_uploaded_count, 0) AS photo_uploaded_count,
    qc.submission_status,
    qc.submitted_at,
    qc.score,
    qc.grade,
    qc.sv_review_status,
    qc.sv_reviewed_by,
    qc.sv_reviewed_at,
    qc.sv_score,
    qc.visit_session_id,
    qf.id AS followup_id,
    qf.status AS followup_status,
    qf.assigned_to_name AS followup_assigned_to_name,
    qf.resolved_at AS followup_resolved_at
  FROM public.qc_checks qc
  JOIN public.qc_templates qt
    ON qt.id = qc.template_id
  JOIN public.restaurants r
    ON r.id = qc.restaurant_id
  LEFT JOIN public.qc_followups qf
    ON qf.source_check_id = qc.id
  WHERE r.store_type = 'direct'
)
SELECT
  -- legacy Office/POS bridge contract
  src.check_id,
  src.store_id,
  src.brand_id,
  src.store_name,
  src.category,
  src.criteria_text,
  src.check_date,
  src.result,
  src.evidence_photo_url,
  src.note,
  src.checked_by,
  src.created_at,

  -- QSC v2 appended fields
  src.template_id,
  src.qsc_domain,
  src.requires_photo,
  src.required_photo_count,
  src.photo_uploaded_count,
  CASE
    WHEN NOT src.requires_photo OR src.required_photo_count = 0 THEN 'not_required'
    WHEN src.photo_uploaded_count <= 0 THEN 'missing'
    WHEN src.photo_uploaded_count < src.required_photo_count THEN 'partial'
    ELSE 'complete'
  END AS photo_status,
  src.submission_status,
  src.submitted_at,
  src.score,
  src.grade,
  src.sv_review_status,
  src.sv_reviewed_by,
  src.sv_reviewed_at,
  src.sv_score,
  (
    src.result = 'fail'
    OR src.sv_review_status = 'rejected'
    OR src.grade = 'risk'
  ) AS improvement_required,
  COALESCE(src.followup_status, 'none') AS followup_status,
  src.followup_id,
  src.followup_assigned_to_name,
  src.followup_resolved_at,
  src.visit_session_id
FROM qsc_source src;

COMMENT ON VIEW public.v_quality_monitoring IS
  'POS-side monitoring snapshot for Office and admin quality review. Legacy columns are preserved and QSC v2 fields are appended.';

-- ------------------------------------------------------------
-- v_qsc_dashboard_summary
-- One row per direct store, summarizing the latest QSC state.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_qsc_dashboard_summary AS
WITH per_check AS (
  SELECT *
  FROM public.v_quality_monitoring
),
latest_check_date AS (
  SELECT
    store_id,
    MAX(check_date) AS latest_check_date
  FROM per_check
  GROUP BY store_id
)
SELECT
  r.id AS store_id,
  r.brand_id,
  r.name AS store_name,
  lcd.latest_check_date,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
  ) AS total_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.submission_status = 'submitted'
  ) AS submitted_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.submission_status = 'pending'
  ) AS pending_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.submission_status = 'overdue'
  ) AS overdue_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.result = 'fail'
  ) AS failed_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.photo_status = 'missing'
  ) AS missing_photo_checks,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.sv_review_status = 'pending'
  ) AS pending_sv_reviews,
  COUNT(pc.check_id) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.followup_status IN ('open', 'in_progress')
  ) AS open_followups,
  ROUND(AVG(pc.score) FILTER (
    WHERE pc.check_date = lcd.latest_check_date
      AND pc.score IS NOT NULL
  ), 2) AS average_score,
  CASE
    WHEN COUNT(pc.check_id) FILTER (
      WHERE pc.check_date = lcd.latest_check_date
    ) = 0 THEN NULL
    ELSE ROUND(
      100.0 * COUNT(pc.check_id) FILTER (
        WHERE pc.check_date = lcd.latest_check_date
          AND pc.submission_status = 'submitted'
      )::numeric
      / COUNT(pc.check_id) FILTER (
        WHERE pc.check_date = lcd.latest_check_date
      )::numeric,
      2
    )
  END AS completion_rate
FROM public.restaurants r
LEFT JOIN latest_check_date lcd
  ON lcd.store_id = r.id
LEFT JOIN per_check pc
  ON pc.store_id = r.id
WHERE r.store_type = 'direct'
GROUP BY r.id, r.brand_id, r.name, lcd.latest_check_date;

COMMENT ON VIEW public.v_qsc_dashboard_summary IS
  'Store-level latest-day QSC snapshot for dashboard KPI cards and summary widgets.';

-- ------------------------------------------------------------
-- v_qsc_store_status
-- Daily store-level status rollup for admin tables and charts.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_qsc_store_status AS
SELECT
  vm.store_id,
  vm.brand_id,
  vm.store_name,
  vm.check_date,
  COUNT(vm.check_id) AS total_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.submission_status = 'submitted'
  ) AS submitted_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.submission_status = 'pending'
  ) AS pending_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.submission_status = 'overdue'
  ) AS overdue_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'pass'
  ) AS pass_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'fail'
  ) AS fail_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'na'
  ) AS na_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.photo_status = 'missing'
  ) AS missing_photo_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.photo_status = 'partial'
  ) AS partial_photo_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.sv_review_status = 'pending'
  ) AS pending_sv_reviews,
  COUNT(vm.check_id) FILTER (
    WHERE vm.followup_status IN ('open', 'in_progress')
  ) AS active_followups,
  ROUND(AVG(vm.score) FILTER (
    WHERE vm.score IS NOT NULL
  ), 2) AS average_score,
  ROUND(AVG(vm.sv_score) FILTER (
    WHERE vm.sv_score IS NOT NULL
  ), 2) AS average_sv_score,
  CASE
    WHEN COUNT(vm.check_id) = 0 THEN NULL
    ELSE ROUND(
      100.0 * COUNT(vm.check_id) FILTER (
        WHERE vm.submission_status = 'submitted'
      )::numeric / COUNT(vm.check_id)::numeric,
      2
    )
  END AS completion_rate,
  CASE
    WHEN COUNT(vm.check_id) = 0 THEN 'no_data'
    WHEN COUNT(vm.check_id) FILTER (
      WHERE vm.submission_status = 'overdue'
         OR vm.result = 'fail'
    ) > 0 THEN 'risk'
    WHEN COUNT(vm.check_id) FILTER (
      WHERE vm.submission_status = 'pending'
         OR vm.photo_status IN ('missing', 'partial')
         OR vm.sv_review_status = 'pending'
    ) > 0 THEN 'caution'
    ELSE 'good'
  END AS store_status
FROM public.v_quality_monitoring vm
GROUP BY vm.store_id, vm.brand_id, vm.store_name, vm.check_date;

COMMENT ON VIEW public.v_qsc_store_status IS
  'Daily store-level QSC rollup for management tables, charts, and mobile summary.';

-- ------------------------------------------------------------
-- v_qsc_item_status
-- Daily item-level status for QSC item pages and weak-point analysis.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_qsc_item_status AS
SELECT
  vm.store_id,
  vm.brand_id,
  vm.store_name,
  vm.check_date,
  vm.template_id,
  vm.category,
  vm.qsc_domain,
  vm.criteria_text,
  COUNT(DISTINCT vm.store_id) AS store_count,
  COUNT(vm.check_id) AS total_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'pass'
  ) AS pass_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'fail'
  ) AS fail_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.result = 'na'
  ) AS na_checks,
  COUNT(vm.check_id) FILTER (
    WHERE vm.photo_status = 'missing'
  ) AS photo_missing_count,
  COUNT(vm.check_id) FILTER (
    WHERE vm.grade = 'good'
       OR (
         vm.grade IS NULL
         AND vm.result = 'pass'
         AND vm.photo_status IN ('complete', 'not_required')
         AND vm.sv_review_status IN ('not_required', 'reviewed')
       )
  ) AS good_count,
  COUNT(vm.check_id) FILTER (
    WHERE vm.grade = 'caution'
       OR (
         vm.grade IS NULL
         AND (
           vm.photo_status IN ('missing', 'partial')
           OR vm.sv_review_status = 'pending'
           OR vm.submission_status = 'pending'
         )
       )
  ) AS caution_count,
  COUNT(vm.check_id) FILTER (
    WHERE vm.grade = 'risk'
       OR vm.result = 'fail'
       OR vm.sv_review_status = 'rejected'
       OR vm.submission_status = 'overdue'
  ) AS risk_count,
  COUNT(vm.check_id) FILTER (
    WHERE vm.sv_review_status = 'pending'
  ) AS pending_sv_reviews,
  COUNT(vm.check_id) FILTER (
    WHERE vm.followup_status IN ('open', 'in_progress')
  ) AS active_followups,
  ROUND(AVG(vm.score) FILTER (
    WHERE vm.score IS NOT NULL
  ), 2) AS average_score,
  ROUND(AVG(vm.sv_score) FILTER (
    WHERE vm.sv_score IS NOT NULL
  ), 2) AS average_sv_score,
  CASE
    WHEN COUNT(vm.check_id) = 0 THEN 'no_data'
    WHEN COUNT(vm.check_id) FILTER (
      WHERE vm.result = 'fail'
    ) > 0 THEN 'risk'
    WHEN COUNT(vm.check_id) FILTER (
      WHERE vm.photo_status IN ('missing', 'partial')
         OR vm.sv_review_status = 'pending'
    ) > 0 THEN 'caution'
    ELSE 'good'
  END AS item_status
FROM public.v_quality_monitoring vm
GROUP BY
  vm.store_id,
  vm.brand_id,
  vm.store_name,
  vm.check_date,
  vm.template_id,
  vm.category,
  vm.qsc_domain,
  vm.criteria_text;

COMMENT ON VIEW public.v_qsc_item_status IS
  'Daily item-level QSC rollup for category analysis, item pages, and weak-point review.';

GRANT SELECT ON public.v_quality_monitoring TO authenticated;
GRANT SELECT ON public.v_qsc_dashboard_summary TO authenticated;
GRANT SELECT ON public.v_qsc_store_status TO authenticated;
GRANT SELECT ON public.v_qsc_item_status TO authenticated;
