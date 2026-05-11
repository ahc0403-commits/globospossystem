-- ============================================================
-- QSC v2 Wave 2: check photo model
-- 2026-05-07
-- Scope:
-- - introduce a normalized photo table for QC/QSC checks
-- - preserve legacy evidence_photo_url on qc_checks
-- - keep existing qc-photos storage policy and folder contract
-- Notes:
-- - storage path must keep restaurant_id as the first folder segment
--   to stay compatible with the existing storage_qc_scoped policy
-- - no automatic backfill from evidence_photo_url in this wave
-- ============================================================

CREATE TABLE IF NOT EXISTS public.qc_check_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  check_id UUID NOT NULL REFERENCES public.qc_checks(id) ON DELETE CASCADE,
  template_id UUID NOT NULL REFERENCES public.qc_templates(id) ON DELETE CASCADE,
  photo_url TEXT NOT NULL,
  storage_path TEXT NOT NULL,
  photo_role TEXT NOT NULL DEFAULT 'staff',
  uploaded_by UUID REFERENCES auth.users(id),
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  taken_at TIMESTAMPTZ,
  is_primary BOOLEAN NOT NULL DEFAULT FALSE,
  caption TEXT,
  CONSTRAINT qc_check_photos_photo_role_check
    CHECK (photo_role IN ('staff', 'sv', 'reference')),
  CONSTRAINT qc_check_photos_storage_path_nonempty_check
    CHECK (btrim(storage_path) <> ''),
  CONSTRAINT qc_check_photos_photo_url_nonempty_check
    CHECK (btrim(photo_url) <> ''),
  CONSTRAINT qc_check_photos_unique_storage_per_check
    UNIQUE (check_id, storage_path)
);

ALTER TABLE public.qc_check_photos ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qc_check_photos'
      AND policyname = 'qc_check_photos_access'
  ) THEN
    CREATE POLICY qc_check_photos_access
    ON public.qc_check_photos
    FOR ALL
    TO authenticated
    USING (
      public.has_any_role(ARRAY['super_admin'])
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) s(store_id)
        WHERE s.store_id = restaurant_id
      )
    )
    WITH CHECK (
      public.has_any_role(ARRAY['super_admin'])
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) s(store_id)
        WHERE s.store_id = restaurant_id
      )
    );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_qc_check_photos_check_uploaded_at
  ON public.qc_check_photos (check_id, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_qc_check_photos_restaurant_check
  ON public.qc_check_photos (restaurant_id, check_id);

CREATE INDEX IF NOT EXISTS idx_qc_check_photos_template_uploaded_at
  ON public.qc_check_photos (template_id, uploaded_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_qc_check_photos_primary_per_check
  ON public.qc_check_photos (check_id)
  WHERE is_primary = TRUE;

COMMENT ON TABLE public.qc_check_photos IS
  'Normalized evidence photo table for QSC v2. Keeps multiple staff/SV/reference photos per QC check.';

COMMENT ON COLUMN public.qc_check_photos.photo_url IS
  'Resolved photo URL used by clients. Legacy evidence_photo_url on qc_checks remains for backward compatibility.';

COMMENT ON COLUMN public.qc_check_photos.storage_path IS
  'Storage object path inside qc-photos bucket. First folder segment must be restaurant_id text.';

COMMENT ON COLUMN public.qc_check_photos.photo_role IS
  'Origin/purpose of the photo: staff, sv, or reference.';

COMMENT ON COLUMN public.qc_check_photos.is_primary IS
  'Whether this photo is the representative photo for the check.';
