-- ============================================================
-- QSC v2 Wave 1: core additive columns
-- 2026-05-07
-- Scope:
-- - additive-only extension of qc_templates and qc_checks
-- - no RPC signature changes
-- - no storage redesign
-- - no Office-side schema changes
-- Notes:
-- - historical rows remain valid
-- - existing QC v1 contracts stay intact
-- - qsc_domain stays nullable in this wave to avoid unsafe forced backfill
-- ============================================================

-- ------------------------------------------------------------
-- qc_templates
-- ------------------------------------------------------------
ALTER TABLE public.qc_templates
  ADD COLUMN IF NOT EXISTS qsc_domain TEXT,
  ADD COLUMN IF NOT EXISTS requires_photo BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS required_photo_count INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS weight NUMERIC(5,2) NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS sort_group TEXT,
  ADD COLUMN IF NOT EXISTS is_sv_required BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_templates_qsc_domain_check'
      AND conrelid = 'public.qc_templates'::regclass
  ) THEN
    ALTER TABLE public.qc_templates
      ADD CONSTRAINT qc_templates_qsc_domain_check
      CHECK (
        qsc_domain IS NULL
        OR qsc_domain IN ('quality', 'service', 'cleanliness')
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_templates_required_photo_count_check'
      AND conrelid = 'public.qc_templates'::regclass
  ) THEN
    ALTER TABLE public.qc_templates
      ADD CONSTRAINT qc_templates_required_photo_count_check
      CHECK (required_photo_count >= 0);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_templates_weight_positive_check'
      AND conrelid = 'public.qc_templates'::regclass
  ) THEN
    ALTER TABLE public.qc_templates
      ADD CONSTRAINT qc_templates_weight_positive_check
      CHECK (weight > 0);
  END IF;
END $$;

COMMENT ON COLUMN public.qc_templates.qsc_domain IS
  'Upper QSC domain for the template: quality, service, cleanliness. Nullable in Wave 1 until category-to-domain mapping is confirmed.';
COMMENT ON COLUMN public.qc_templates.requires_photo IS
  'Whether evidence photos are required for this template in QSC v2.';
COMMENT ON COLUMN public.qc_templates.required_photo_count IS
  'Minimum number of evidence photos expected for this template.';
COMMENT ON COLUMN public.qc_templates.weight IS
  'Weight used for QSC score calculation.';
COMMENT ON COLUMN public.qc_templates.sort_group IS
  'Optional grouping key for mobile and admin presentation.';
COMMENT ON COLUMN public.qc_templates.is_sv_required IS
  'Whether SV review is required for checks created from this template.';

-- Conservative backfill for existing rows.
UPDATE public.qc_templates
SET
  requires_photo = COALESCE(requires_photo, TRUE),
  required_photo_count = COALESCE(required_photo_count, 1),
  weight = COALESCE(weight, 1),
  is_sv_required = COALESCE(is_sv_required, FALSE)
WHERE
  requires_photo IS DISTINCT FROM COALESCE(requires_photo, TRUE)
  OR required_photo_count IS DISTINCT FROM COALESCE(required_photo_count, 1)
  OR weight IS DISTINCT FROM COALESCE(weight, 1)
  OR is_sv_required IS DISTINCT FROM COALESCE(is_sv_required, FALSE);

-- ------------------------------------------------------------
-- qc_checks
-- ------------------------------------------------------------
ALTER TABLE public.qc_checks
  ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS due_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS submission_status TEXT NOT NULL DEFAULT 'submitted',
  ADD COLUMN IF NOT EXISTS photo_required_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS photo_uploaded_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS score NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS grade TEXT,
  ADD COLUMN IF NOT EXISTS sv_review_status TEXT NOT NULL DEFAULT 'not_required',
  ADD COLUMN IF NOT EXISTS sv_reviewed_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS sv_reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sv_score NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS sv_note TEXT,
  ADD COLUMN IF NOT EXISTS visit_session_id UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_checks_submission_status_check'
      AND conrelid = 'public.qc_checks'::regclass
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_submission_status_check
      CHECK (submission_status IN ('pending', 'submitted', 'overdue'));
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_checks_photo_required_count_check'
      AND conrelid = 'public.qc_checks'::regclass
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_photo_required_count_check
      CHECK (photo_required_count >= 0);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_checks_photo_uploaded_count_check'
      AND conrelid = 'public.qc_checks'::regclass
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_photo_uploaded_count_check
      CHECK (photo_uploaded_count >= 0);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_checks_grade_check'
      AND conrelid = 'public.qc_checks'::regclass
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_grade_check
      CHECK (
        grade IS NULL
        OR grade IN ('good', 'caution', 'risk')
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'qc_checks_sv_review_status_check'
      AND conrelid = 'public.qc_checks'::regclass
  ) THEN
    ALTER TABLE public.qc_checks
      ADD CONSTRAINT qc_checks_sv_review_status_check
      CHECK (
        sv_review_status IN ('not_required', 'pending', 'reviewed', 'rejected')
      );
  END IF;
END $$;

COMMENT ON COLUMN public.qc_checks.scheduled_at IS
  'Optional scheduled inspection time for QSC v2.';
COMMENT ON COLUMN public.qc_checks.due_at IS
  'Optional due time for QSC completion and overdue calculation.';
COMMENT ON COLUMN public.qc_checks.submitted_at IS
  'Explicit submission timestamp. created_at remains row creation time.';
COMMENT ON COLUMN public.qc_checks.submission_status IS
  'QSC submission lifecycle state: pending, submitted, overdue.';
COMMENT ON COLUMN public.qc_checks.photo_required_count IS
  'Expected number of photos for this check at submission time.';
COMMENT ON COLUMN public.qc_checks.photo_uploaded_count IS
  'Number of photos currently attached to this check.';
COMMENT ON COLUMN public.qc_checks.score IS
  'Operational score recorded for the check.';
COMMENT ON COLUMN public.qc_checks.grade IS
  'Presentation-grade bucket for the check: good, caution, risk.';
COMMENT ON COLUMN public.qc_checks.sv_review_status IS
  'SV review lifecycle state for the check.';
COMMENT ON COLUMN public.qc_checks.sv_reviewed_by IS
  'SV reviewer auth user id.';
COMMENT ON COLUMN public.qc_checks.sv_reviewed_at IS
  'Timestamp when the SV review was completed.';
COMMENT ON COLUMN public.qc_checks.sv_score IS
  'SV-evaluated score for the check.';
COMMENT ON COLUMN public.qc_checks.sv_note IS
  'SV review note or rejection reason.';
COMMENT ON COLUMN public.qc_checks.visit_session_id IS
  'Optional grouping key linking several checks to a single visit/review session.';

-- Historical backfill:
-- - existing rows are already submitted checks
-- - preserve representative photo semantics from evidence_photo_url
UPDATE public.qc_checks qc
SET
  submitted_at = COALESCE(qc.submitted_at, qc.created_at),
  submission_status = COALESCE(NULLIF(qc.submission_status, ''), 'submitted'),
  photo_required_count = COALESCE(qc.photo_required_count, 0),
  photo_uploaded_count = COALESCE(
    qc.photo_uploaded_count,
    CASE
      WHEN qc.evidence_photo_url IS NOT NULL AND btrim(qc.evidence_photo_url) <> '' THEN 1
      ELSE 0
    END
  ),
  sv_review_status = COALESCE(NULLIF(qc.sv_review_status, ''), 'not_required')
WHERE
  qc.submitted_at IS NULL
  OR qc.submission_status IS NULL
  OR qc.submission_status = ''
  OR qc.photo_required_count IS NULL
  OR qc.photo_uploaded_count IS NULL
  OR qc.sv_review_status IS NULL
  OR qc.sv_review_status = '';
