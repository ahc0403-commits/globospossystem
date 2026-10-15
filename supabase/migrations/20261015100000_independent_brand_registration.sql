-- Independent brand registration. No store or Office records are created here.
BEGIN;

CREATE INDEX IF NOT EXISTS brands_name_id_page_idx ON public.brands(lower(name), id);
CREATE INDEX IF NOT EXISTS tax_entity_brands_brand_lookup_idx
  ON public.tax_entity_brands(brand_id, tax_entity_id);

CREATE OR REPLACE FUNCTION public.require_brand_admin_v1()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE auth_id = auth.uid() AND is_active AND role = 'super_admin'
  ) THEN RAISE EXCEPTION 'BRAND_ADMIN_FORBIDDEN'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_brand_groups_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth AS $$
BEGIN
  PERFORM public.require_brand_admin_v1();
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name, 'company_name', c.name
  ) ORDER BY g.name, g.id), '[]'::jsonb)
  FROM public.brand_master g JOIN public.companies c ON c.id = g.company_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_brands_v1(
  p_search text DEFAULT '', p_after_name text DEFAULT NULL,
  p_after_id uuid DEFAULT NULL, p_limit integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 50);
  v_result jsonb;
BEGIN
  PERFORM public.require_brand_admin_v1();
  IF length(COALESCE(p_search, '')) > 100 THEN RAISE EXCEPTION 'BRAND_SEARCH_TOO_LONG'; END IF;
  IF (p_after_name IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'BRAND_CURSOR_INVALID';
  END IF;
  -- Aggregate each relationship separately, limited to the requested page.
  -- Joining both raw one-to-many relations would multiply counts and payloads.
  WITH candidates AS MATERIALIZED (
    SELECT b.id, b.name, b.code, b.brand_master_id
    FROM public.brands b
    WHERE (COALESCE(btrim(p_search), '') = ''
      OR strpos(lower(b.name), lower(btrim(p_search))) > 0
      OR strpos(lower(b.code), lower(btrim(p_search))) > 0)
      AND (p_after_id IS NULL OR (lower(b.name), b.id) > (lower(p_after_name), p_after_id))
    ORDER BY lower(b.name), b.id LIMIT v_limit + 1
  ), page AS MATERIALIZED (
    SELECT * FROM candidates ORDER BY lower(name), id LIMIT v_limit
  ), links AS (
    SELECT l.brand_id, array_agg(l.tax_entity_id ORDER BY l.tax_entity_id) ids,
      array_agg(t.name ORDER BY l.tax_entity_id) names
    FROM public.tax_entity_brands l JOIN page p ON p.id = l.brand_id
    JOIN public.tax_entity t ON t.id = l.tax_entity_id GROUP BY l.brand_id
  ), counts AS (
    SELECT r.brand_id, count(*) store_count
    FROM public.restaurants r JOIN page p ON p.id = r.brand_id GROUP BY r.brand_id
  )
  SELECT jsonb_build_object('items', COALESCE(jsonb_agg(
    to_jsonb(p) || jsonb_build_object(
      'tax_entity_ids', COALESCE(l.ids, '{}'::uuid[]),
      'tax_entity_names', COALESCE(l.names, '{}'::text[]),
      'store_count', COALESCE(c.store_count, 0)
    ) ORDER BY lower(p.name), p.id), '[]'::jsonb),
    'has_more', (SELECT count(*) > v_limit FROM candidates)) INTO v_result
  FROM page p LEFT JOIN links l ON l.brand_id = p.id
  LEFT JOIN counts c ON c.brand_id = p.id;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_brand_v1(
  p_brand_id uuid, p_name text, p_code text, p_brand_master_id uuid,
  p_tax_entity_ids uuid[] DEFAULT '{}'::uuid[]
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_name text := btrim(COALESCE(p_name, ''));
  v_code text := lower(btrim(COALESCE(p_code, '')));
  v_ids uuid[];
  v_brand public.brands%ROWTYPE;
  v_company_id uuid;
BEGIN
  PERFORM public.require_brand_admin_v1();
  IF p_brand_id IS NULL THEN RAISE EXCEPTION 'BRAND_REQUEST_ID_REQUIRED'; END IF;
  IF v_name = '' OR length(v_name) > 120 THEN RAISE EXCEPTION 'BRAND_NAME_INVALID'; END IF;
  IF v_code !~ '^[a-z0-9][a-z0-9_-]{1,63}$' THEN RAISE EXCEPTION 'BRAND_CODE_INVALID'; END IF;
  IF cardinality(COALESCE(p_tax_entity_ids, '{}'::uuid[])) > 100 THEN
    RAISE EXCEPTION 'BRAND_LINK_LIMIT';
  END IF;
  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::uuid[]) INTO v_ids
  FROM unnest(p_tax_entity_ids) x WHERE x IS NOT NULL;
  SELECT company_id INTO v_company_id FROM public.brand_master WHERE id = p_brand_master_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BRAND_GROUP_REQUIRED'; END IF;
  IF (SELECT count(*) FROM public.tax_entity WHERE id = ANY(v_ids)) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'BRAND_LEGAL_ENTITY_INVALID';
  END IF;
  -- Serialize normalized-code races without rewriting legacy brand codes.
  PERFORM pg_advisory_xact_lock(hashtextextended('brand-code:' || v_code, 0));
  SELECT * INTO v_brand FROM public.brands WHERE id = p_brand_id;
  IF FOUND THEN
    -- A retry after a lost response is safe only for the same actor and request.
    IF v_brand.name <> v_name OR v_brand.code <> v_code
      OR v_brand.brand_master_id <> p_brand_master_id
      OR NOT EXISTS (
        SELECT 1 FROM public.audit_logs WHERE entity_id = p_brand_id
          AND action = 'admin_create_brand_v1' AND actor_id = auth.uid()
          AND details -> 'tax_entity_ids' = to_jsonb(v_ids)
      ) THEN RAISE EXCEPTION 'BRAND_REQUEST_CONFLICT'; END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM public.brands WHERE lower(btrim(code)) = v_code) THEN
      RAISE EXCEPTION 'BRAND_CODE_EXISTS';
    END IF;
    INSERT INTO public.brands(id, name, code, company_id, brand_master_id)
    VALUES(p_brand_id, v_name, v_code, v_company_id, p_brand_master_id)
    RETURNING * INTO v_brand;
    INSERT INTO public.tax_entity_brands(tax_entity_id, brand_id, created_by)
    SELECT x, p_brand_id, auth.uid() FROM unnest(v_ids) x;
    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES(auth.uid(), 'admin_create_brand_v1', 'brands', p_brand_id,
      jsonb_build_object('name', v_name, 'code', v_code, 'tax_entity_ids', v_ids));
  END IF;
  -- A replay may happen after another administrator has added more links.
  SELECT COALESCE(array_agg(tax_entity_id ORDER BY tax_entity_id), '{}'::uuid[]) INTO v_ids
  FROM public.tax_entity_brands WHERE brand_id = p_brand_id;
  RETURN jsonb_build_object('id', v_brand.id, 'name', v_brand.name, 'code', v_brand.code,
    'brand_master_id', v_brand.brand_master_id, 'tax_entity_ids', v_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_link_brand_tax_entities_v1(
  p_brand_id uuid, p_tax_entity_ids uuid[]
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_brand public.brands%ROWTYPE;
  v_ids uuid[];
  v_inserted integer;
BEGIN
  PERFORM public.require_brand_admin_v1();
  IF cardinality(COALESCE(p_tax_entity_ids, '{}'::uuid[])) > 100 THEN
    RAISE EXCEPTION 'BRAND_LINK_LIMIT';
  END IF;
  SELECT * INTO v_brand FROM public.brands WHERE id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BRAND_NOT_FOUND'; END IF;
  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::uuid[]) INTO v_ids
  FROM unnest(p_tax_entity_ids) x WHERE x IS NOT NULL;
  IF (SELECT count(*) FROM public.tax_entity WHERE id = ANY(v_ids)) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'BRAND_LEGAL_ENTITY_INVALID';
  END IF;
  INSERT INTO public.tax_entity_brands(tax_entity_id, brand_id, created_by)
  SELECT x, p_brand_id, auth.uid() FROM unnest(v_ids) x ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted > 0 THEN
    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES(auth.uid(), 'admin_link_brand_tax_entities_v1', 'brands', p_brand_id,
      jsonb_build_object('tax_entity_ids', v_ids));
  END IF;
  SELECT COALESCE(array_agg(tax_entity_id ORDER BY tax_entity_id), '{}'::uuid[]) INTO v_ids
  FROM public.tax_entity_brands WHERE brand_id = p_brand_id;
  RETURN jsonb_build_object('id', v_brand.id, 'name', v_brand.name, 'code', v_brand.code,
    'brand_master_id', v_brand.brand_master_id, 'tax_entity_ids', v_ids);
END;
$$;

REVOKE ALL ON FUNCTION public.require_brand_admin_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_brand_groups_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_list_brands_v1(text,text,uuid,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create_brand_v1(uuid,text,text,uuid,uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_link_brand_tax_entities_v1(uuid,uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_brand_groups_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_brands_v1(text,text,uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_brand_v1(uuid,text,text,uuid,uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_brand_tax_entities_v1(uuid,uuid[]) TO authenticated;

COMMIT;
