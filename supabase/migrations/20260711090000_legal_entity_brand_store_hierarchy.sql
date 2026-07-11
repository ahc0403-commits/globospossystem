-- Legal entity -> brand -> store hierarchy.
-- Additive only: public.restaurants remains the physical store table and all
-- existing store identities are preserved.

-- Keep the exact pre-migration mappings and replaced object definitions so the
-- operator rollback can restore only this migration. Rows are captured once.
CREATE TABLE IF NOT EXISTS public.hierarchy_20260711090000_object_backup (
  object_identity text PRIMARY KEY,
  object_kind text NOT NULL,
  definition text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.hierarchy_20260711090000_object_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.hierarchy_20260711090000_object_backup FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.hierarchy_20260711090000_photo_backup (
  store_id uuid PRIMARY KEY,
  prior_tax_entity_id uuid NOT NULL,
  prior_brand_id uuid NOT NULL,
  prior_brand_suggested_tax_entity_id uuid,
  captured_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.hierarchy_20260711090000_photo_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.hierarchy_20260711090000_photo_backup FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.hierarchy_20260711090000_history_backup (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  tax_entity_id uuid NOT NULL,
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  reason text,
  created_at timestamptz NOT NULL,
  created_by uuid
);
ALTER TABLE public.hierarchy_20260711090000_history_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.hierarchy_20260711090000_history_backup FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.hierarchy_20260711090000_backup_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  snapshot_completed_at timestamptz NOT NULL
);
ALTER TABLE public.hierarchy_20260711090000_backup_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.hierarchy_20260711090000_backup_state FROM PUBLIC, anon, authenticated;

DO $initial_snapshot$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.hierarchy_20260711090000_backup_state
    WHERE singleton = true
  ) THEN
    INSERT INTO public.hierarchy_20260711090000_object_backup (
      object_identity, object_kind, definition
    )
    SELECT
      p.oid::regprocedure::text,
      'function',
      pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid IN (
      to_regprocedure('public.admin_create_restaurant(text,text,text,text,numeric,uuid,text)'),
      to_regprocedure('public.admin_update_restaurant(uuid,text,text,text,text,numeric,uuid,text)'),
      to_regprocedure('public.sync_restaurant_store_type_from_tax_entity()'),
      to_regprocedure('public.sync_stores_after_tax_entity_owner_change()'),
      to_regprocedure('public.guard_pending_tax_entity_meinvoice_activation()')
    )
    ON CONFLICT (object_identity) DO NOTHING;

    INSERT INTO public.hierarchy_20260711090000_object_backup (
      object_identity, object_kind, definition
    )
    SELECT
      format('%I.%I:%I', n.nspname, c.relname, t.tgname),
      'trigger',
      pg_get_triggerdef(t.oid, true)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal
      AND n.nspname = 'public'
      AND (
        (c.relname = 'restaurants' AND t.tgname = 'trg_sync_restaurant_store_type_from_tax_entity')
        OR (c.relname = 'tax_entity' AND t.tgname = 'trg_sync_stores_after_tax_entity_owner_change')
        OR (c.relname = 'meinvoice_tax_entity_config' AND t.tgname = 'trg_guard_pending_tax_entity_meinvoice_activation')
      )
    ON CONFLICT (object_identity) DO NOTHING;

    INSERT INTO public.hierarchy_20260711090000_photo_backup (
      store_id,
      prior_tax_entity_id,
      prior_brand_id,
      prior_brand_suggested_tax_entity_id
    )
    SELECT r.id, r.tax_entity_id, r.brand_id, b.suggested_tax_entity_id
    FROM public.restaurants r
    JOIN public.brands b ON b.id = r.brand_id
    JOIN public.tax_entity te ON te.id = r.tax_entity_id
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND te.tax_code = 'PLACEHOLDER_DEV_000'
    ON CONFLICT (store_id) DO NOTHING;

    INSERT INTO public.hierarchy_20260711090000_history_backup
    SELECT h.*
    FROM public.store_tax_entity_history h
    JOIN public.hierarchy_20260711090000_photo_backup b ON b.store_id = h.store_id
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.hierarchy_20260711090000_backup_state (
      singleton, snapshot_completed_at
    ) VALUES (true, now());
  END IF;
END;
$initial_snapshot$;

ALTER TABLE public.tax_entity
  ADD COLUMN IF NOT EXISTS onboarding_status text NOT NULL DEFAULT 'ready';

ALTER TABLE public.tax_entity
  DROP CONSTRAINT IF EXISTS tax_entity_onboarding_status_check;
ALTER TABLE public.tax_entity
  ADD CONSTRAINT tax_entity_onboarding_status_check
  CHECK (onboarding_status IN ('pending_tax_profile', 'ready'));

UPDATE public.tax_entity
SET onboarding_status = 'pending_tax_profile'
WHERE tax_code = 'PLACEHOLDER_DEV_000';

COMMENT ON COLUMN public.tax_entity.onboarding_status IS
  'pending_tax_profile blocks meInvoice activation; ready means the legal name and Vietnamese tax code have been verified.';

CREATE TABLE IF NOT EXISTS public.tax_entity_brands (
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id) ON DELETE RESTRICT,
  brand_id uuid NOT NULL REFERENCES public.brands(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (tax_entity_id, brand_id)
);

COMMENT ON TABLE public.tax_entity_brands IS
  'Allowed legal-entity/brand pairs. A legal entity may operate many brands and the same brand may be operated by many legal entities.';

ALTER TABLE public.tax_entity_brands ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'tax_entity_brands'
      AND policyname = 'tax_entity_brands_read_scope'
  ) THEN
    CREATE POLICY tax_entity_brands_read_scope
    ON public.tax_entity_brands
    FOR SELECT TO authenticated
    USING (
      public.is_super_admin()
      OR EXISTS (
        SELECT 1
        FROM public.user_accessible_tax_entities(auth.uid()) entity_scope(tax_entity_id)
        WHERE entity_scope.tax_entity_id = tax_entity_brands.tax_entity_id
      )
    );
  END IF;
END;
$$;

GRANT SELECT ON public.tax_entity_brands TO authenticated;
GRANT ALL ON public.tax_entity_brands TO service_role;

-- Preserve every currently valid physical store before enforcing the pair FK.
INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
SELECT DISTINCT r.tax_entity_id, r.brand_id
FROM public.restaurants r
WHERE r.tax_entity_id IS NOT NULL
  AND r.brand_id IS NOT NULL
ON CONFLICT (tax_entity_id, brand_id) DO NOTHING;

-- Brands without a physical store still need the same fallback that the v1
-- create RPC historically used. This preserves first-store creation while v2
-- clients move to explicit legal-entity selection.
INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
SELECT
  COALESCE(b.suggested_tax_entity_id, placeholder.id),
  b.id
FROM public.brands b
CROSS JOIN public.tax_entity placeholder
WHERE placeholder.tax_code = 'PLACEHOLDER_DEV_000'
ON CONFLICT (tax_entity_id, brand_id) DO NOTHING;

-- AKJ is intentionally created with a non-fiscal marker. This is not a real
-- Vietnamese tax code and cannot be activated for invoice issuance.
INSERT INTO public.tax_entity (
  id,
  tax_code,
  name,
  owner_type,
  einvoice_provider,
  data_source,
  onboarding_status
)
VALUES (
  'a6bda671-4179-5a29-a798-76357b42b497',
  'PENDING_AKJ_TAX_PROFILE',
  'AKJ (tax profile pending)',
  'internal',
  'meinvoice',
  'VNPT_EPAY',
  'pending_tax_profile'
)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    owner_type = EXCLUDED.owner_type,
    onboarding_status = 'pending_tax_profile',
    updated_at = now()
WHERE public.tax_entity.tax_code = 'PENDING_AKJ_TAX_PROFILE';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.tax_entity te
    WHERE id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
      AND owner_type = 'internal'
      AND (
        (
          tax_code = 'PENDING_AKJ_TAX_PROFILE'
          AND onboarding_status = 'pending_tax_profile'
        )
        OR EXISTS (
          SELECT 1
          FROM public.tax_entity_brands teb
          WHERE teb.tax_entity_id = te.id
            AND teb.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
        )
      )
  ) THEN
    RAISE EXCEPTION 'AKJ_PENDING_TAX_ENTITY_ID_CONFLICT';
  END IF;
END;
$$;

-- PHOTO OBJET has a stable brand identity in the POS contract. The guarded
-- insert keeps this migration usable before or after that brand is seeded.
INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
SELECT
  'a6bda671-4179-5a29-a798-76357b42b497'::uuid,
  b.id
FROM public.brands b
WHERE b.id = '77000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (tax_entity_id, brand_id) DO NOTHING;

-- Existing PHOTO OBJET stores still on the shared development placeholder are
-- deterministically assigned to the AKJ pending profile. Stores already mapped
-- to another legal entity are left untouched, which supports external operators.
UPDATE public.store_tax_entity_history h
SET effective_to = b.captured_at
FROM public.hierarchy_20260711090000_photo_backup b
WHERE h.store_id = b.store_id
  AND h.tax_entity_id = b.prior_tax_entity_id
  AND h.effective_to IS NULL;

INSERT INTO public.store_tax_entity_history (
  store_id,
  tax_entity_id,
  effective_from,
  effective_to,
  reason,
  created_by
)
SELECT
  b.store_id,
  b.prior_tax_entity_id,
  LEAST(COALESCE(r.created_at, b.captured_at), b.captured_at),
  b.captured_at,
  'hierarchy_20260711090000_photo_objet_source;actor=migration;destination=a6bda671-4179-5a29-a798-76357b42b497',
  NULL
FROM public.hierarchy_20260711090000_photo_backup b
JOIN public.restaurants r ON r.id = b.store_id
WHERE NOT EXISTS (
  SELECT 1
  FROM public.store_tax_entity_history h
  WHERE h.store_id = b.store_id
    AND h.tax_entity_id = b.prior_tax_entity_id
    AND h.effective_to = b.captured_at
);

UPDATE public.restaurants r
SET tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
FROM public.hierarchy_20260711090000_photo_backup b
WHERE r.id = b.store_id
  AND r.tax_entity_id = b.prior_tax_entity_id;

INSERT INTO public.store_tax_entity_history (
  store_id,
  tax_entity_id,
  effective_from,
  effective_to,
  reason,
  created_by
)
SELECT
  b.store_id,
  'a6bda671-4179-5a29-a798-76357b42b497'::uuid,
  b.captured_at,
  NULL,
  format(
    'hierarchy_20260711090000_photo_objet_destination;actor=migration;source=%s',
    b.prior_tax_entity_id
  ),
  NULL
FROM public.hierarchy_20260711090000_photo_backup b
JOIN public.restaurants r ON r.id = b.store_id
WHERE r.tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
  AND NOT EXISTS (
    SELECT 1
    FROM public.store_tax_entity_history h
    WHERE h.store_id = b.store_id
      AND h.tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
      AND h.effective_to IS NULL
      AND h.reason LIKE 'hierarchy_20260711090000_photo_objet_destination;%'
  );

UPDATE public.brands
SET suggested_tax_entity_id = 'a6bda671-4179-5a29-a798-76357b42b497'::uuid
WHERE id = '77000000-0000-0000-0000-000000000001'::uuid
  AND (
    suggested_tax_entity_id IS NULL
    OR suggested_tax_entity_id = '00000000-0000-0000-0000-000000000011'::uuid
  );

INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id)
SELECT DISTINCT r.tax_entity_id, r.brand_id
FROM public.restaurants r
WHERE r.tax_entity_id IS NOT NULL
  AND r.brand_id IS NOT NULL
ON CONFLICT (tax_entity_id, brand_id) DO NOTHING;

ALTER TABLE public.restaurants
  DROP CONSTRAINT IF EXISTS restaurants_tax_entity_brand_fk;
ALTER TABLE public.restaurants
  ADD CONSTRAINT restaurants_tax_entity_brand_fk
  FOREIGN KEY (tax_entity_id, brand_id)
  REFERENCES public.tax_entity_brands (tax_entity_id, brand_id)
  ON UPDATE RESTRICT
  ON DELETE RESTRICT
  NOT VALID;
ALTER TABLE public.restaurants
  VALIDATE CONSTRAINT restaurants_tax_entity_brand_fk;

CREATE INDEX IF NOT EXISTS idx_restaurants_tax_entity_brand
  ON public.restaurants (tax_entity_id, brand_id);

CREATE OR REPLACE FUNCTION public.sync_restaurant_store_type_from_tax_entity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_owner_type text;
BEGIN
  SELECT te.owner_type
  INTO v_owner_type
  FROM public.tax_entity te
  WHERE te.id = NEW.tax_entity_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_NOT_FOUND';
  END IF;

  NEW.store_type := CASE v_owner_type
    WHEN 'internal' THEN 'direct'
    WHEN 'external' THEN 'external'
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_restaurant_store_type_from_tax_entity
  ON public.restaurants;
CREATE TRIGGER trg_sync_restaurant_store_type_from_tax_entity
BEFORE INSERT OR UPDATE OF tax_entity_id, store_type
ON public.restaurants
FOR EACH ROW
EXECUTE FUNCTION public.sync_restaurant_store_type_from_tax_entity();

CREATE OR REPLACE FUNCTION public.sync_stores_after_tax_entity_owner_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.owner_type IS NOT DISTINCT FROM OLD.owner_type THEN
    RETURN NEW;
  END IF;

  UPDATE public.restaurants
  SET store_type = CASE NEW.owner_type
    WHEN 'internal' THEN 'direct'
    WHEN 'external' THEN 'external'
  END
  WHERE tax_entity_id = NEW.id;

  IF NEW.owner_type = 'external'
     AND to_regclass('ops.stores') IS NOT NULL
     AND 2 = (
       SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'ops' AND table_name = 'stores'
         AND column_name IN ('pos_store_id', 'status')
     ) THEN
    EXECUTE
      'UPDATE ops.stores SET pos_store_id = NULL, status = ''inactive'' '
      'WHERE pos_store_id IN (SELECT id FROM public.restaurants WHERE tax_entity_id = $1)'
      USING NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_stores_after_tax_entity_owner_change
  ON public.tax_entity;
CREATE TRIGGER trg_sync_stores_after_tax_entity_owner_change
AFTER UPDATE OF owner_type ON public.tax_entity
FOR EACH ROW
EXECUTE FUNCTION public.sync_stores_after_tax_entity_owner_change();

-- Existing store_type values become compatibility projections of owner_type.
UPDATE public.restaurants r
SET store_type = CASE te.owner_type
  WHEN 'internal' THEN 'direct'
  WHEN 'external' THEN 'external'
END
FROM public.tax_entity te
WHERE te.id = r.tax_entity_id
  AND r.store_type IS DISTINCT FROM CASE te.owner_type
    WHEN 'internal' THEN 'direct'
    WHEN 'external' THEN 'external'
  END;

COMMENT ON COLUMN public.restaurants.store_type IS
  'Compatibility projection only: direct for internal tax_entity.owner_type and external for external. Callers cannot override it.';

CREATE OR REPLACE VIEW public.v_office_eligible_stores
WITH (security_invoker = true)
AS
SELECT
  r.id AS store_id,
  r.name AS store_name,
  r.address,
  r.is_active,
  r.tax_entity_id,
  te.name AS tax_entity_name,
  te.tax_code,
  r.brand_id,
  b.code AS brand_code,
  b.name AS brand_name
FROM public.restaurants r
JOIN public.tax_entity te ON te.id = r.tax_entity_id
JOIN public.brands b ON b.id = r.brand_id
JOIN public.tax_entity_brands teb
  ON teb.tax_entity_id = r.tax_entity_id
 AND teb.brand_id = r.brand_id
WHERE te.owner_type = 'internal';

COMMENT ON VIEW public.v_office_eligible_stores IS
  'Canonical Office bridge store source. External legal entities are excluded even when a caller supplies a store id directly.';

REVOKE ALL ON public.v_office_eligible_stores FROM PUBLIC, anon;
GRANT SELECT ON public.v_office_eligible_stores TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.guard_pending_tax_entity_meinvoice_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.integration_status = 'active'
     AND EXISTS (
       SELECT 1
       FROM public.tax_entity te
       WHERE te.id = NEW.tax_entity_id
         AND te.onboarding_status = 'pending_tax_profile'
     ) THEN
    RAISE EXCEPTION 'TAX_ENTITY_TAX_PROFILE_NOT_READY';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_pending_tax_entity_meinvoice_activation
  ON public.meinvoice_tax_entity_config;
CREATE TRIGGER trg_guard_pending_tax_entity_meinvoice_activation
BEFORE INSERT OR UPDATE OF integration_status, tax_entity_id
ON public.meinvoice_tax_entity_config
FOR EACH ROW
EXECUTE FUNCTION public.guard_pending_tax_entity_meinvoice_activation();

CREATE OR REPLACE FUNCTION public.link_office_pending_store_for_pos_store_v2(
  p_pos_store_id uuid,
  p_name text,
  p_brand_id uuid,
  p_tax_entity_id uuid,
  p_address text DEFAULT NULL,
  p_office_store_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_owner_type text;
  v_office_store_id uuid;
BEGIN
  SELECT te.owner_type
  INTO v_owner_type
  FROM public.tax_entity te
  JOIN public.tax_entity_brands teb
    ON teb.tax_entity_id = te.id
   AND teb.brand_id = p_brand_id
  WHERE te.id = p_tax_entity_id;

  IF NOT FOUND OR v_owner_type <> 'internal' THEN
    RAISE EXCEPTION 'OFFICE_LINK_INTERNAL_ENTITY_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants r
    WHERE r.id = p_pos_store_id
      AND r.tax_entity_id = p_tax_entity_id
      AND r.brand_id = p_brand_id
  ) THEN
    RAISE EXCEPTION 'OFFICE_LINK_STORE_HIERARCHY_MISMATCH';
  END IF;

  -- The Office schema is not deployed in POS production. Defer the bridge
  -- without blocking POS store creation; use it only when the complete legacy
  -- Office contract is present in the same database.
  IF to_regclass('ops.stores') IS NULL
     OR 5 <> (
       SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'ops' AND table_name = 'stores'
         AND column_name IN ('id', 'pos_store_id', 'name', 'address', 'brand_id')
     )
     OR to_regprocedure(
       'public.ensure_office_brand_for_pos_brand(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.link_office_pending_store_for_pos_store(uuid,text,uuid,text,uuid)'
     ) IS NULL THEN
    RETURN NULL;
  END IF;

  EXECUTE
    'SELECT id FROM ops.stores WHERE pos_store_id = $1 LIMIT 1'
    INTO v_office_store_id
    USING p_pos_store_id;

  IF v_office_store_id IS NOT NULL THEN
    EXECUTE 'SELECT public.ensure_office_brand_for_pos_brand($1)'
      USING p_brand_id;
    EXECUTE
      'UPDATE ops.stores SET name = $1, address = COALESCE($2, address), '
      'brand_id = $3 WHERE id = $4'
      USING p_name, p_address, p_brand_id, v_office_store_id;
    RETURN v_office_store_id;
  END IF;

  EXECUTE
    'SELECT public.link_office_pending_store_for_pos_store($1, $2, $3, $4, $5)'
    INTO v_office_store_id
    USING p_pos_store_id, p_name, p_brand_id, p_address, p_office_store_id;
  RETURN v_office_store_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_tax_entity_v2(
  p_tax_entity_id uuid,
  p_tax_code text,
  p_name text,
  p_owner_type text,
  p_onboarding_status text DEFAULT 'ready'
) RETURNS public.tax_entity
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.tax_entity%ROWTYPE;
  v_result public.tax_entity%ROWTYPE;
  v_id uuid := COALESCE(p_tax_entity_id, gen_random_uuid());
  v_tax_code text := NULLIF(btrim(COALESCE(p_tax_code, '')), '');
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_owner_type text := lower(NULLIF(btrim(COALESCE(p_owner_type, '')), ''));
  v_status text := lower(NULLIF(btrim(COALESCE(p_onboarding_status, '')), ''));
  v_store public.restaurants%ROWTYPE;
  v_office_store_id uuid;
  v_office_links_created integer := 0;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'TAX_ENTITY_MUTATION_FORBIDDEN';
  END IF;

  IF v_tax_code IS NULL OR v_name IS NULL THEN
    RAISE EXCEPTION 'TAX_ENTITY_PROFILE_REQUIRED';
  END IF;
  IF v_owner_type NOT IN ('internal', 'external') THEN
    RAISE EXCEPTION 'TAX_ENTITY_OWNER_TYPE_INVALID';
  END IF;
  IF v_status NOT IN ('pending_tax_profile', 'ready') THEN
    RAISE EXCEPTION 'TAX_ENTITY_ONBOARDING_STATUS_INVALID';
  END IF;
  IF v_status = 'ready' AND v_tax_code LIKE 'PENDING_%' THEN
    RAISE EXCEPTION 'TAX_ENTITY_REAL_TAX_CODE_REQUIRED';
  END IF;

  SELECT * INTO v_existing
  FROM public.tax_entity
  WHERE id = v_id
  FOR UPDATE;

  INSERT INTO public.tax_entity (
    id, tax_code, name, owner_type, einvoice_provider, data_source,
    onboarding_status, created_at, updated_at
  )
  VALUES (
    v_id, v_tax_code, v_name, v_owner_type, 'meinvoice', 'VNPT_EPAY',
    v_status, now(), now()
  )
  ON CONFLICT (id) DO UPDATE
  SET tax_code = EXCLUDED.tax_code,
      name = EXCLUDED.name,
      owner_type = EXCLUDED.owner_type,
      onboarding_status = EXCLUDED.onboarding_status,
      updated_at = now()
  RETURNING * INTO v_result;

  IF v_result.owner_type = 'internal'
     AND COALESCE(v_existing.owner_type, 'external') = 'external' THEN
    FOR v_store IN
      SELECT r.*
      FROM public.restaurants r
      WHERE r.tax_entity_id = v_result.id
    LOOP
      v_office_store_id := public.link_office_pending_store_for_pos_store_v2(
        v_store.id,
        v_store.name,
        v_store.brand_id,
        v_store.tax_entity_id,
        v_store.address,
        NULL
      );
      IF v_office_store_id IS NOT NULL THEN
        v_office_links_created := v_office_links_created + 1;
      END IF;
    END LOOP;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_upsert_tax_entity_v2',
    'tax_entity',
    v_result.id,
    jsonb_build_object(
      'old_values', CASE WHEN v_existing.id IS NULL THEN NULL ELSE jsonb_build_object(
        'tax_code', v_existing.tax_code,
        'name', v_existing.name,
        'owner_type', v_existing.owner_type,
        'onboarding_status', v_existing.onboarding_status
      ) END,
      'new_values', jsonb_build_object(
        'tax_code', v_result.tax_code,
        'name', v_result.name,
        'owner_type', v_result.owner_type,
        'onboarding_status', v_result.onboarding_status
      ),
      'office_links_created', v_office_links_created
    )
  );

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_tax_entity_brand_link_v2(
  p_tax_entity_id uuid,
  p_brand_id uuid,
  p_is_active boolean DEFAULT TRUE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'TAX_ENTITY_BRAND_MUTATION_FORBIDDEN';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.tax_entity WHERE id = p_tax_entity_id) THEN
    RAISE EXCEPTION 'TAX_ENTITY_NOT_FOUND';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.brands WHERE id = p_brand_id) THEN
    RAISE EXCEPTION 'RESTAURANT_BRAND_NOT_FOUND';
  END IF;

  IF COALESCE(p_is_active, TRUE) THEN
    INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id, created_by)
    VALUES (p_tax_entity_id, p_brand_id, auth.uid())
    ON CONFLICT (tax_entity_id, brand_id) DO NOTHING;
  ELSE
    IF EXISTS (
      SELECT 1 FROM public.restaurants
      WHERE tax_entity_id = p_tax_entity_id AND brand_id = p_brand_id
    ) THEN
      RAISE EXCEPTION 'TAX_ENTITY_BRAND_LINK_IN_USE';
    END IF;
    DELETE FROM public.tax_entity_brands
    WHERE tax_entity_id = p_tax_entity_id AND brand_id = p_brand_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_set_tax_entity_brand_link_v2', 'tax_entity',
    p_tax_entity_id,
    jsonb_build_object('brand_id', p_brand_id, 'is_active', COALESCE(p_is_active, TRUE))
  );

  RETURN jsonb_build_object(
    'tax_entity_id', p_tax_entity_id,
    'brand_id', p_brand_id,
    'is_active', COALESCE(p_is_active, TRUE)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_restaurant_v2(
  p_name text,
  p_slug text,
  p_operation_mode text,
  p_tax_entity_id uuid,
  p_brand_id uuid,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_office_store_id uuid DEFAULT NULL
) RETURNS public.restaurants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.restaurants%ROWTYPE;
  v_new_store_id uuid := gen_random_uuid();
  v_owner_type text;
  v_office_store_id uuid;
  v_changed_at timestamptz := now();
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode text := lower(NULLIF(btrim(COALESCE(p_operation_mode, '')), ''));
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_CREATE_FORBIDDEN';
  END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED'; END IF;
  IF v_operation_mode IS NULL THEN RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED'; END IF;

  SELECT te.owner_type INTO v_owner_type
  FROM public.tax_entity te
  JOIN public.tax_entity_brands teb
    ON teb.tax_entity_id = te.id AND teb.brand_id = p_brand_id
  WHERE te.id = p_tax_entity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_BRAND_INVALID'; END IF;

  INSERT INTO public.restaurants (
    id, name, address, slug, operation_mode, per_person_charge,
    tax_entity_id, brand_id, store_type, is_active, created_at
  ) VALUES (
    v_new_store_id, v_name, NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''), v_operation_mode,
    p_per_person_charge, p_tax_entity_id, p_brand_id,
    CASE v_owner_type WHEN 'internal' THEN 'direct' WHEN 'external' THEN 'external' END,
    TRUE, v_changed_at
  ) RETURNING * INTO v_created;

  INSERT INTO public.store_tax_entity_history (
    store_id, tax_entity_id, effective_from, reason, created_by
  ) VALUES (
    v_created.id,
    v_created.tax_entity_id,
    v_changed_at,
    format(
      'admin_create_restaurant_v2;actor=%s;source=none;destination=%s;reason=initial_assignment',
      v_actor.id,
      v_created.tax_entity_id
    ),
    v_actor.id
  );

  IF v_owner_type = 'internal' THEN
    v_office_store_id := public.link_office_pending_store_for_pos_store_v2(
      v_created.id, v_created.name, v_created.brand_id, v_created.tax_entity_id,
      v_created.address, p_office_store_id
    );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_create_restaurant_v2', 'restaurants', v_created.id,
    jsonb_build_object(
      'store_id', v_created.id,
      'tax_entity_id', v_created.tax_entity_id,
      'brand_id', v_created.brand_id,
      'owner_type', v_owner_type,
      'store_type', v_created.store_type,
      'office_store_id', v_office_store_id
    )
  );
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_restaurant_v2(
  p_store_id uuid,
  p_name text,
  p_slug text,
  p_operation_mode text,
  p_tax_entity_id uuid,
  p_brand_id uuid,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_office_store_id uuid DEFAULT NULL
) RETURNS public.restaurants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_owner_type text;
  v_office_store_id uuid;
  v_changed_at timestamptz := now();
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode text := lower(NULLIF(btrim(COALESCE(p_operation_mode, '')), ''));
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_UPDATE_FORBIDDEN';
  END IF;

  SELECT * INTO v_existing
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_NOT_FOUND'; END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED'; END IF;
  IF v_operation_mode IS NULL THEN RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED'; END IF;

  SELECT te.owner_type INTO v_owner_type
  FROM public.tax_entity te
  JOIN public.tax_entity_brands teb
    ON teb.tax_entity_id = te.id AND teb.brand_id = p_brand_id
  WHERE te.id = p_tax_entity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_BRAND_INVALID'; END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = NULLIF(btrim(COALESCE(p_address, '')), ''),
      slug = NULLIF(btrim(COALESCE(p_slug, '')), ''),
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      tax_entity_id = p_tax_entity_id,
      brand_id = p_brand_id,
      store_type = CASE v_owner_type WHEN 'internal' THEN 'direct' WHEN 'external' THEN 'external' END
  WHERE id = p_store_id
  RETURNING * INTO v_updated;

  IF v_existing.tax_entity_id IS DISTINCT FROM v_updated.tax_entity_id THEN
    UPDATE public.store_tax_entity_history
    SET effective_to = v_changed_at
    WHERE store_id = v_updated.id
      AND tax_entity_id = v_existing.tax_entity_id
      AND effective_to IS NULL;

    INSERT INTO public.store_tax_entity_history (
      store_id, tax_entity_id, effective_from, reason, created_by
    ) VALUES (
      v_updated.id,
      v_updated.tax_entity_id,
      v_changed_at,
      format(
        'admin_update_restaurant_v2;actor=%s;source=%s;destination=%s;reason=legal_entity_reassignment',
        v_actor.id,
        v_existing.tax_entity_id,
        v_updated.tax_entity_id
      ),
      v_actor.id
    );
  END IF;

  IF v_owner_type = 'internal' THEN
    v_office_store_id := public.link_office_pending_store_for_pos_store_v2(
      v_updated.id, v_updated.name, v_updated.brand_id, v_updated.tax_entity_id,
      v_updated.address, p_office_store_id
    );
  ELSIF to_regclass('ops.stores') IS NOT NULL
        AND 2 = (
          SELECT count(*) FROM information_schema.columns
          WHERE table_schema = 'ops' AND table_name = 'stores'
            AND column_name IN ('pos_store_id', 'status')
        ) THEN
    EXECUTE
      'UPDATE ops.stores SET pos_store_id = NULL, status = ''inactive'' '
      'WHERE pos_store_id = $1'
      USING p_store_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_update_restaurant_v2', 'restaurants', v_updated.id,
    jsonb_build_object(
      'old_values', jsonb_build_object(
        'tax_entity_id', v_existing.tax_entity_id,
        'brand_id', v_existing.brand_id,
        'store_type', v_existing.store_type
      ),
      'new_values', jsonb_build_object(
        'tax_entity_id', v_updated.tax_entity_id,
        'brand_id', v_updated.brand_id,
        'owner_type', v_owner_type,
        'store_type', v_updated.store_type,
        'office_store_id', v_office_store_id
      )
    )
  );
  RETURN v_updated;
END;
$$;

-- Legacy create remains callable. p_store_type is retained for API compatibility
-- but owner_type decides the stored value and Office behavior.
DROP FUNCTION IF EXISTS public.admin_create_restaurant(
  text, text, text, text, numeric, uuid, text, uuid
);
CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  p_name text,
  p_slug text,
  p_operation_mode text,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_brand_id uuid DEFAULT NULL,
  p_store_type text DEFAULT 'direct'
) RETURNS public.restaurants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_tax_entity_id uuid;
  v_link_count integer;
BEGIN
  IF p_brand_id IS NULL THEN RAISE EXCEPTION 'RESTAURANT_BRAND_REQUIRED'; END IF;
  PERFORM p_store_type;

  SELECT count(*)
  INTO v_link_count
  FROM public.tax_entity_brands teb
  WHERE teb.brand_id = p_brand_id;

  SELECT b.suggested_tax_entity_id
  INTO v_tax_entity_id
  FROM public.brands b
  JOIN public.tax_entity_brands teb
    ON teb.brand_id = b.id
   AND teb.tax_entity_id = b.suggested_tax_entity_id
  WHERE b.id = p_brand_id;

  IF v_tax_entity_id IS NULL AND v_link_count = 1 THEN
    SELECT teb.tax_entity_id INTO v_tax_entity_id
    FROM public.tax_entity_brands teb
    WHERE teb.brand_id = p_brand_id;
  END IF;

  IF v_tax_entity_id IS NULL OR (v_link_count > 1 AND NOT EXISTS (
    SELECT 1 FROM public.brands b
    WHERE b.id = p_brand_id AND b.suggested_tax_entity_id = v_tax_entity_id
  )) THEN
    RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_REQUIRED_USE_V2';
  END IF;

  RETURN public.admin_create_restaurant_v2(
    p_name => p_name,
    p_slug => p_slug,
    p_operation_mode => p_operation_mode,
    p_tax_entity_id => v_tax_entity_id,
    p_brand_id => p_brand_id,
    p_address => p_address,
    p_per_person_charge => p_per_person_charge,
    p_office_store_id => NULL
  );
END;
$$;

-- Legacy update preserves the store's legal entity. Call v2 to change entity.
-- p_store_type is retained for API compatibility and is intentionally ignored.
CREATE OR REPLACE FUNCTION public.admin_update_restaurant(
  p_store_id uuid,
  p_name text,
  p_slug text,
  p_operation_mode text,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_brand_id uuid DEFAULT NULL,
  p_store_type text DEFAULT 'direct'
) RETURNS public.restaurants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_owner_type text;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_slug text := NULLIF(btrim(COALESCE(p_slug, '')), '');
  v_operation_mode text := lower(NULLIF(btrim(COALESCE(p_operation_mode, '')), ''));
  v_address text := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  PERFORM p_store_type;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED'; END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED'; END IF;
  IF v_operation_mode IS NULL THEN RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED'; END IF;
  IF p_brand_id IS NULL THEN RAISE EXCEPTION 'RESTAURANT_BRAND_REQUIRED'; END IF;

  SELECT * INTO v_existing
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_NOT_FOUND'; END IF;

  -- Preserve the historical admin/store_admin/brand_admin scope matrix.
  -- The v2 entry point remains super-admin-only because it can move entities.
  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  SELECT te.owner_type INTO v_owner_type
  FROM public.tax_entity te
  JOIN public.tax_entity_brands teb
    ON teb.tax_entity_id = te.id
   AND teb.brand_id = p_brand_id
  WHERE te.id = v_existing.tax_entity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_BRAND_INVALID'; END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = v_address,
      slug = v_slug,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      brand_id = p_brand_id,
      store_type = CASE v_owner_type
        WHEN 'internal' THEN 'direct'
        WHEN 'external' THEN 'external'
      END
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF v_owner_type = 'internal' THEN
    PERFORM public.link_office_pending_store_for_pos_store_v2(
      v_updated.id,
      v_updated.name,
      v_updated.brand_id,
      v_updated.tax_entity_id,
      v_updated.address,
      NULL
    );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_update_restaurant', 'restaurants', v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.id,
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'slug', v_existing.slug,
        'operation_mode', v_existing.operation_mode,
        'address', v_existing.address,
        'per_person_charge', v_existing.per_person_charge,
        'brand_id', v_existing.brand_id,
        'store_type', v_existing.store_type
      ),
      'new_values', jsonb_build_object(
        'name', v_updated.name,
        'slug', v_updated.slug,
        'operation_mode', v_updated.operation_mode,
        'address', v_updated.address,
        'per_person_charge', v_updated.per_person_charge,
        'brand_id', v_updated.brand_id,
        'store_type', v_updated.store_type
      ),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.link_office_pending_store_for_pos_store_v2(uuid, text, uuid, uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.link_office_pending_store_for_pos_store_v2(uuid, text, uuid, uuid, text, uuid)
  TO service_role;

-- The legacy implementation cannot validate tax_entity_id because its signature
-- predates the hierarchy. Keep trusted Office compatibility without exposing a
-- direct path around the complete tuple checks in v2.
DO $$
BEGIN
  IF to_regprocedure(
    'public.link_office_pending_store_for_pos_store(uuid,text,uuid,text,uuid)'
  ) IS NOT NULL THEN
    EXECUTE
      'REVOKE ALL ON FUNCTION public.link_office_pending_store_for_pos_store'
      '(uuid, text, uuid, text, uuid) FROM PUBLIC, anon, authenticated';
    EXECUTE
      'GRANT EXECUTE ON FUNCTION public.link_office_pending_store_for_pos_store'
      '(uuid, text, uuid, text, uuid) TO service_role';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_upsert_tax_entity_v2(uuid, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_tax_entity_v2(uuid, text, text, text, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_set_tax_entity_brand_link_v2(uuid, uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_tax_entity_brand_link_v2(uuid, uuid, boolean)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_create_restaurant_v2(text, text, text, uuid, uuid, text, numeric, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_restaurant_v2(text, text, text, uuid, uuid, text, numeric, uuid)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_update_restaurant_v2(uuid, text, text, text, uuid, uuid, text, numeric, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_restaurant_v2(uuid, text, text, text, uuid, uuid, text, numeric, uuid)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_create_restaurant(text, text, text, text, numeric, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_restaurant(text, text, text, text, numeric, uuid, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_update_restaurant(uuid, text, text, text, text, numeric, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_restaurant(uuid, text, text, text, text, numeric, uuid, text)
  TO authenticated, service_role;
