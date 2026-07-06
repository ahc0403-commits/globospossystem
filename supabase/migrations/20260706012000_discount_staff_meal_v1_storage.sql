BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'discount-proofs',
  'discount-proofs',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS storage_discount_proofs_scoped ON storage.objects;
DROP POLICY IF EXISTS storage_discount_proofs_select ON storage.objects;
DROP POLICY IF EXISTS storage_discount_proofs_insert ON storage.objects;

CREATE POLICY storage_discount_proofs_select ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'discount-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR public.is_super_admin()
  )
);

CREATE POLICY storage_discount_proofs_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'discount-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR public.is_super_admin()
  )
);

-- No authenticated UPDATE/DELETE policies: uploaded discount proofs are
-- immutable audit evidence. Service-role maintenance still bypasses RLS.

COMMIT;
