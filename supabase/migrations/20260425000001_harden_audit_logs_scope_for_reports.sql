BEGIN;

DROP POLICY IF EXISTS audit_logs_admin_read ON public.audit_logs;

CREATE POLICY audit_logs_admin_read
ON public.audit_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND (
        u.role = 'super_admin'
        OR (
          u.role IN ('admin', 'store_admin', 'brand_admin')
          AND (
            (
              entity_type = 'restaurants'
              AND entity_id IN (
                SELECT s.store_id
                FROM public.user_accessible_stores(auth.uid()) s(store_id)
              )
            )
            OR (
              NULLIF(details ->> 'store_id', '')::uuid IN (
                SELECT s.store_id
                FROM public.user_accessible_stores(auth.uid()) s(store_id)
              )
            )
            OR (
              NULLIF(details ->> 'restaurant_id', '')::uuid IN (
                SELECT s.store_id
                FROM public.user_accessible_stores(auth.uid()) s(store_id)
              )
            )
          )
        )
      )
  )
);

COMMIT;
