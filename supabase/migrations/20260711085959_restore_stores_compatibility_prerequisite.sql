-- Restore the real legacy read contract before 20260711090000 first declares
-- RPCs returning its composite type. Existing environments already have this
-- view from an out-of-band setup; fresh migration replay did not create it.
-- No business rows or Auth mappings are created or changed.
DO $compatibility$
BEGIN
  IF to_regclass('public.stores') IS NULL THEN
    EXECUTE $view$
      CREATE VIEW public.stores WITH (security_invoker = true) AS
      SELECT id, name, address, slug, operation_mode, per_person_charge,
             is_active, created_at, brand_id, store_type
      FROM public.restaurants
    $view$;
    GRANT SELECT ON public.stores TO authenticated, service_role;
    REVOKE ALL ON public.stores FROM PUBLIC, anon;
  ELSIF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'stores' AND c.relkind = 'v'
  ) THEN
    RAISE EXCEPTION 'STORES_COMPATIBILITY_VIEW_REQUIRED';
  END IF;
END;
$compatibility$;
