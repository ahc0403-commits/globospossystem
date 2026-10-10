-- Public company names only; no buyer/contact cache or payment/invoice mutation.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE public.company_tax_lookup_settings (
  store_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false
);
CREATE TABLE public.company_tax_lookup_rate (
  actor_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  window_start timestamptz NOT NULL,
  used integer NOT NULL CHECK (used BETWEEN 0 AND 10)
);
CREATE TABLE public.company_tax_lookup_slots (
  slot smallint PRIMARY KEY CHECK (slot BETWEEN 1 AND 2),
  lease_id uuid,
  auth_user_id uuid,
  lease_until timestamptz NOT NULL DEFAULT '-infinity'
);
INSERT INTO public.company_tax_lookup_slots(slot) VALUES (1), (2);
ALTER TABLE public.company_tax_lookup_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_tax_lookup_rate ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_tax_lookup_slots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_tax_lookup_settings, public.company_tax_lookup_rate,
  public.company_tax_lookup_slots FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.company_tax_lookup_settings, public.company_tax_lookup_rate,
  public.company_tax_lookup_slots TO service_role;

-- Only Edge's verified Auth user id is accepted; browsers cannot claim leases.
CREATE FUNCTION public.pos_claim_company_tax_lookup(p_auth_user_id uuid, p_store_id uuid, p_lease_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor_id uuid; v_actor_role text; bucket public.company_tax_lookup_rate%ROWTYPE;
  available_slot smallint; checked_at timestamptz;
BEGIN
  SELECT u.id, u.role INTO v_actor_id, v_actor_role FROM public.users u
    WHERE u.auth_id = $1 AND u.is_active LIMIT 1;
  IF v_actor_id IS NULL OR v_actor_role IS NULL OR v_actor_role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin')
    OR NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id = $2 AND is_active)
    OR v_actor_role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores($1) scope(store_id) WHERE scope.store_id = $2
    ) THEN RETURN jsonb_build_object('outcome','forbidden'); END IF;
  IF $3 IS NULL THEN RETURN jsonb_build_object('outcome','forbidden'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.company_tax_lookup_settings WHERE store_id = $2 AND enabled)
    THEN RETURN jsonb_build_object('outcome','disabled'); END IF;
  INSERT INTO public.company_tax_lookup_rate(actor_id,window_start,used)
    VALUES (v_actor_id,clock_timestamp(),0) ON CONFLICT ON CONSTRAINT company_tax_lookup_rate_pkey DO NOTHING;
  SELECT * INTO bucket FROM public.company_tax_lookup_rate r WHERE r.actor_id = v_actor_id FOR UPDATE;
  checked_at := clock_timestamp();
  IF checked_at >= bucket.window_start + interval '60 seconds' THEN bucket.used := 0; bucket.window_start := checked_at; END IF;
  IF bucket.used >= 10 THEN RETURN jsonb_build_object('outcome','rate_limited'); END IF;
  SELECT slot INTO available_slot FROM public.company_tax_lookup_slots
    WHERE lease_until <= checked_at ORDER BY slot FOR UPDATE SKIP LOCKED LIMIT 1;
  IF available_slot IS NULL THEN RETURN jsonb_build_object('outcome','rate_limited'); END IF;
  UPDATE public.company_tax_lookup_rate r SET used = bucket.used + 1, window_start = bucket.window_start
    WHERE r.actor_id = v_actor_id;
  UPDATE public.company_tax_lookup_slots SET lease_id = $3, auth_user_id = $1,
    lease_until = checked_at + interval '10 seconds' WHERE slot = available_slot;
  RETURN jsonb_build_object('outcome','claimed');
END; $$;
CREATE FUNCTION public.pos_release_company_tax_lookup(p_auth_user_id uuid, p_lease_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  UPDATE public.company_tax_lookup_slots SET lease_id = NULL, auth_user_id = NULL, lease_until = '-infinity'
    WHERE auth_user_id = $1 AND lease_id = $2;
$$;
REVOKE ALL ON FUNCTION public.pos_claim_company_tax_lookup(uuid,uuid,uuid),
  public.pos_release_company_tax_lookup(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_claim_company_tax_lookup(uuid,uuid,uuid),
  public.pos_release_company_tax_lookup(uuid,uuid) TO service_role;
DO $$ BEGIN
  IF has_function_privilege('authenticated','public.pos_claim_company_tax_lookup(uuid,uuid,uuid)','EXECUTE')
    OR has_function_privilege('anon','public.pos_release_company_tax_lookup(uuid,uuid)','EXECUTE')
    OR has_table_privilege('authenticated','public.company_tax_lookup_settings','SELECT')
    OR (SELECT count(*) FROM public.company_tax_lookup_slots) <> 2
    OR EXISTS (SELECT 1 FROM public.company_tax_lookup_settings WHERE enabled)
    THEN RAISE EXCEPTION 'COMPANY_TAX_LOOKUP_POLICY_DRIFT'; END IF;
END; $$;
COMMIT;
