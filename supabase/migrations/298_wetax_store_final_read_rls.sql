BEGIN;

-- ADR-014 store-final authorization update:
-- POS-facing WeTax reads must resolve through the caller's accessible store set.
-- Shared tax_entity_id is not a sufficient basis for sibling-store visibility.

CREATE OR REPLACE FUNCTION public.can_access_einvoice_job(
  p_job_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.einvoice_jobs ej
    JOIN public.orders o
      ON o.id = ej.order_id
    JOIN public.user_accessible_stores(auth.uid()) s(store_id)
      ON s.store_id = o.restaurant_id
    WHERE ej.id = p_job_id
  );
$$;

COMMENT ON FUNCTION public.can_access_einvoice_job(uuid) IS
  'Returns whether the current auth user can access the einvoice job through an accessible store. SECURITY DEFINER avoids nested RLS collapse on indirect joins.';

DROP POLICY IF EXISTS "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache;
CREATE POLICY "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache
  FOR SELECT USING (
    is_super_admin() OR
    (
      has_any_role(ARRAY['cashier','admin','store_admin','brand_admin'])
      AND EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) s(store_id)
        WHERE s.store_id = b2b_buyer_cache.store_id
      )
    )
  );

DROP POLICY IF EXISTS "einvoice_jobs_admin_read" ON public.einvoice_jobs;
CREATE POLICY "einvoice_jobs_admin_read" ON public.einvoice_jobs
  FOR SELECT USING (
    is_super_admin() OR
    (
      has_any_role(ARRAY['admin','store_admin','brand_admin'])
      AND public.can_access_einvoice_job(einvoice_jobs.id)
    )
  );

DROP POLICY IF EXISTS "einvoice_events_admin_read" ON public.einvoice_events;
CREATE POLICY "einvoice_events_admin_read" ON public.einvoice_events
  FOR SELECT USING (
    is_super_admin() OR
    (
      has_any_role(ARRAY['admin','store_admin','brand_admin'])
      AND public.can_access_einvoice_job(einvoice_events.job_id)
    )
  );

COMMIT;
