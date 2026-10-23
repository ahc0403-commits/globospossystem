-- Additive reduced-schema fixture. Full live-schema parity/load is separate.
CREATE TABLE IF NOT EXISTS "public"."kds_realtime_rollouts" (
    "restaurant_id" "uuid" NOT NULL,
    "mode" "text" DEFAULT 'legacy'::"text" NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kds_realtime_rollouts_mode_check" CHECK (("mode" = ANY (ARRAY['legacy'::"text", 'shadow'::"text", 'active'::"text"])))
);
CREATE TABLE IF NOT EXISTS "public"."kds_store_revisions" (
    "restaurant_id" "uuid" NOT NULL,
    "current_revision" bigint DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kds_store_revisions_current_revision_check" CHECK (("current_revision" >= 0))
);
CREATE TABLE IF NOT EXISTS "public"."store_service_areas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "stored_code" "text" NOT NULL,
    "display_name" "text",
    "physical_floor" "text",
    CONSTRAINT "store_area_name_length" CHECK ((("length"("display_name") >= 1) AND ("length"("display_name") <= 80))),
    CONSTRAINT "store_area_physical_floor_length" CHECK ((("physical_floor" IS NULL) OR (("length"("physical_floor") >= 1) AND ("length"("physical_floor") <= 40)))),
    CONSTRAINT "store_service_areas_stored_code_check" CHECK ((("length"("stored_code") >= 1) AND ("length"("stored_code") <= 80)))
);
CREATE TABLE IF NOT EXISTS "public"."store_account_onboarding_jobs" (
    "id" "uuid" NOT NULL,
    "store_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "input" "jsonb" NOT NULL,
    "accounts" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "lease_id" "uuid",
    "lease_until" timestamp with time zone,
    "attempts" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "store_account_onboarding_jobs_accounts_check" CHECK ((("jsonb_typeof"("accounts") = 'array'::"text") AND (("jsonb_array_length"("accounts") >= 1) AND ("jsonb_array_length"("accounts") <= 50)))),
    CONSTRAINT "store_account_onboarding_jobs_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'running'::"text", 'partial'::"text", 'complete'::"text"])))
);
CREATE OR REPLACE FUNCTION "public"."get_kds_sync_config"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session_id uuid;
  v_mode text := 'legacy';
  v_revision bigint := 0;
BEGIN
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'mode', 'legacy', 'assigned', false,
      'restaurant_id', v_user.restaurant_id, 'revision', 0
    );
  END IF;
  SELECT session.id INTO v_session_id
  FROM public.emergency_fulfillment_sessions session
  WHERE session.restaurant_id = v_assignment.restaurant_id
    AND session.status = 'active';
  SELECT COALESCE(rollout.mode, 'legacy') INTO v_mode
  FROM (SELECT 1) seed
  LEFT JOIN public.kds_realtime_rollouts rollout
    ON rollout.restaurant_id = v_assignment.restaurant_id;
  SELECT COALESCE(revision.current_revision, 0) INTO v_revision
  FROM (SELECT 1) seed
  LEFT JOIN public.kds_store_revisions revision
    ON revision.restaurant_id = v_assignment.restaurant_id;
  RETURN jsonb_build_object(
    'mode', v_mode,
    'assigned', true,
    'restaurant_id', v_assignment.restaurant_id,
    'session_id', v_session_id,
    'station_type', v_assignment.station_type,
    'floor_label', v_assignment.floor_label,'service_area_configuration_known',EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=v_assignment.restaurant_id AND input?'config'),'service_area_codes',CASE WHEN v_assignment.station_type='tray' AND EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=v_assignment.restaurant_id AND input?'config') THEN coalesce((SELECT jsonb_agg(stored_code ORDER BY stored_code) FROM store_service_areas WHERE restaurant_id=v_assignment.restaurant_id),'[]'::jsonb) ELSE to_jsonb(public.store_assignment_area_codes_v1(v_assignment)) END,
    'revision', v_revision
  );
END;
$$;

CREATE FUNCTION get_store_fulfillment_mode(uuid) RETURNS text LANGUAGE sql AS $$ SELECT 'paperless'::text $$;
CREATE FUNCTION store_workflow_device_v1(uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION kds_uses_direct_floor_workflow(uuid) RETURNS boolean LANGUAGE sql AS $$ SELECT $1='273b057e-3b69-46e3-93c1-6194c2802849'::uuid $$;
