-- Additive operating identities and immutable legacy baseline versions.
-- Runtime authority remains with the existing POS/KDS contracts in this phase.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE public.store_service_areas (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 stored_code text NOT NULL CHECK(length(stored_code) BETWEEN 1 AND 80),
 UNIQUE(restaurant_id,id), UNIQUE(restaurant_id,stored_code)
);
CREATE TABLE public.store_service_stations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 code text NOT NULL CHECK(length(code) BETWEEN 1 AND 100),
 kind text NOT NULL CHECK(kind IN ('kitchen','tray','floor')),
 area_id uuid,
 UNIQUE(restaurant_id,id), UNIQUE(restaurant_id,code),
 FOREIGN KEY(restaurant_id,area_id) REFERENCES public.store_service_areas(restaurant_id,id),
 CHECK((kind='floor')=(area_id IS NOT NULL))
);
CREATE TABLE public.store_operating_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 version_no integer NOT NULL CHECK(version_no>0),
 definition_schema_version smallint NOT NULL DEFAULT 1 CHECK(definition_schema_version=1),
 source_hash text NOT NULL CHECK(source_hash ~ '^[0-9a-f]{32}$'),
 legacy_workflow text NOT NULL CHECK(legacy_workflow IN ('kitchen_tray_floor','kitchen_floor')),
 fulfillment_mode text NOT NULL CHECK(fulfillment_mode IN ('paperless','pos_print')),
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(restaurant_id,id), UNIQUE(restaurant_id,version_no)
);
CREATE TABLE public.store_operating_profiles (
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id),
 baseline_version_id uuid,
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 runtime_authority text NOT NULL DEFAULT 'legacy' CHECK(runtime_authority='legacy'),
 updated_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(restaurant_id,baseline_version_id) REFERENCES public.store_operating_versions(restaurant_id,id)
);
CREATE TABLE public.store_operating_version_stations (
 restaurant_id uuid NOT NULL,
 version_id uuid NOT NULL,
 station_id uuid NOT NULL,
 PRIMARY KEY(version_id,station_id),
 UNIQUE(restaurant_id,version_id,station_id),
 FOREIGN KEY(restaurant_id,version_id) REFERENCES public.store_operating_versions(restaurant_id,id),
 FOREIGN KEY(restaurant_id,station_id) REFERENCES public.store_service_stations(restaurant_id,id)
);
CREATE TABLE public.store_operating_version_assignments (
 restaurant_id uuid NOT NULL,
 version_id uuid NOT NULL,
 station_id uuid NOT NULL,
 -- Snapshot identifiers deliberately survive account/legacy-assignment retirement.
 -- Current account existence and store ownership are checked when capturing.
 user_id uuid NOT NULL,
 legacy_assignment_id uuid NOT NULL,
 PRIMARY KEY(version_id,user_id),
 FOREIGN KEY(restaurant_id,version_id,station_id)
  REFERENCES public.store_operating_version_stations(restaurant_id,version_id,station_id)
);
CREATE INDEX store_operating_assignments_station ON public.store_operating_version_assignments(restaurant_id,station_id,version_id);
CREATE INDEX store_service_stations_area ON public.store_service_stations(restaurant_id,area_id);

-- One bounded snapshot per store; no per-table/menu/account lookup loop.
CREATE FUNCTION public.store_operating_source_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH settings AS (
  SELECT r.id,coalesce(s.fulfillment_mode,'pos_print') mode,
   coalesce(s.kds_workflow,CASE WHEN r.id='273b057e-3b69-46e3-93c1-6194c2802849'
    THEN 'kitchen_floor' ELSE 'kitchen_tray_floor' END) workflow
  FROM public.restaurants r LEFT JOIN public.restaurant_settings s ON s.restaurant_id=r.id WHERE r.id=p_store_id
 ), rooms AS (
  SELECT jsonb_agg(jsonb_build_object('id',t.id,'number',t.table_number,'floor',t.floor_label)
   ORDER BY t.id) data,count(*) count FROM (SELECT id,table_number,floor_label FROM public.tables
   WHERE restaurant_id=p_store_id ORDER BY id LIMIT 2001)t
 ), accounts AS (
  SELECT jsonb_agg(jsonb_build_object('id',a.id,'user_id',a.user_id,'kind',a.station_type,
   'floor',a.floor_label,'user_active',u.is_active,'user_store_id',u.restaurant_id) ORDER BY a.id) data,count(*) count
  FROM (SELECT id,user_id,station_type,floor_label FROM public.emergency_station_assignments
   WHERE restaurant_id=p_store_id AND is_active ORDER BY id LIMIT 201)a
  LEFT JOIN public.users u ON u.id=a.user_id
 )
 SELECT jsonb_build_object('workflow',s.workflow,'fulfillment_mode',s.mode,
  'tables',coalesce(r.data,'[]'::jsonb),'assignments',coalesce(a.data,'[]'::jsonb),
  'within_bounds',r.count<=2000 AND a.count<=200)
 FROM settings s CROSS JOIN rooms r CROSS JOIN accounts a;
$$;
REVOKE ALL ON FUNCTION public.store_operating_source_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_get_store_operating_profile_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE source jsonb; result jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 source:=public.store_operating_source_v1(p_store_id);
 IF source IS NULL THEN RAISE EXCEPTION 'OPERATING_PROFILE_STORE_NOT_FOUND'; END IF;
 IF NOT (source->>'within_bounds')::boolean THEN RAISE EXCEPTION 'OPERATING_PROFILE_LIMIT'; END IF;
 SELECT jsonb_build_object('restaurant_id',p_store_id,'revision',coalesce(p.revision,0),
  'runtime_authority','legacy','definition_schema_version',1,'baseline_version_id',p.baseline_version_id,
  'version_no',v.version_no,'source_matches',coalesce(v.source_hash=md5(source::text),false),
  'source_hash',md5(source::text),'workflow',source->>'workflow',
  'fulfillment_mode',source->>'fulfillment_mode',
  'stations',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'code',s.code,'kind',s.kind,
    'area_id',s.area_id,'stored_floor',a.stored_code,'user_ids',coalesce(x.users,'[]'::jsonb)) ORDER BY s.code)
    FROM public.store_operating_version_stations vs JOIN public.store_service_stations s ON s.id=vs.station_id
    LEFT JOIN public.store_service_areas a ON a.id=s.area_id
    LEFT JOIN (SELECT station_id,jsonb_agg(user_id ORDER BY user_id) users
      FROM public.store_operating_version_assignments WHERE version_id=p.baseline_version_id GROUP BY station_id)x ON x.station_id=s.id
    WHERE vs.version_id=p.baseline_version_id),'[]'::jsonb)) INTO result
 FROM (SELECT p_store_id id) scope LEFT JOIN public.store_operating_profiles p ON p.restaurant_id=scope.id
 LEFT JOIN public.store_operating_versions v ON v.id=p.baseline_version_id;
 RETURN result;
END;
$$;

CREATE FUNCTION public.admin_capture_store_operating_baseline_v1(p_store_id uuid,p_expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE source jsonb; profile public.store_operating_profiles%ROWTYPE;
 version_id uuid; next_version integer; captured_hash text;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF p_expected_revision IS NULL OR p_expected_revision<0 THEN RAISE EXCEPTION 'OPERATING_PROFILE_INPUT_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id::text,0));
 PERFORM 1 FROM public.restaurants WHERE id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'OPERATING_PROFILE_STORE_NOT_FOUND'; END IF;
 INSERT INTO public.store_operating_profiles(restaurant_id) VALUES(p_store_id) ON CONFLICT DO NOTHING;
 SELECT * INTO profile FROM public.store_operating_profiles WHERE restaurant_id=p_store_id FOR UPDATE;
 source:=public.store_operating_source_v1(p_store_id);
 IF NOT (source->>'within_bounds')::boolean THEN RAISE EXCEPTION 'OPERATING_PROFILE_LIMIT'; END IF;
 captured_hash:=md5(source::text);
 -- A repeated capture returns the same immutable version; a stale *different*
 -- capture cannot overwrite a newer baseline.
 IF EXISTS(SELECT 1 FROM public.store_operating_versions v WHERE v.id=profile.baseline_version_id AND v.source_hash=captured_hash) THEN
  RETURN public.admin_get_store_operating_profile_v1(p_store_id);
 END IF;
 IF profile.revision<>p_expected_revision THEN RAISE EXCEPTION 'OPERATING_PROFILE_CHANGED'; END IF;
 IF source->>'workflow'='kitchen_floor' AND EXISTS(
  SELECT 1 FROM jsonb_array_elements(source->'assignments') a WHERE a->>'kind'='tray'
 ) THEN RAISE EXCEPTION 'OPERATING_PROFILE_LEGACY_ASSIGNMENT_CONFLICT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(source->'assignments') a
  WHERE (a->>'user_active')::boolean IS DISTINCT FROM true
   OR (a->>'user_store_id')::uuid IS DISTINCT FROM p_store_id
   OR a->>'kind' NOT IN ('kitchen','tray','floor')
   OR (a->>'kind'='floor' AND nullif(a->>'floor','') IS NULL)) THEN
  RAISE EXCEPTION 'OPERATING_PROFILE_LEGACY_ASSIGNMENT_CONFLICT'; END IF;

 INSERT INTO public.store_service_areas(restaurant_id,stored_code)
 SELECT p_store_id,floor FROM (
  SELECT t->>'floor' floor FROM jsonb_array_elements(source->'tables') t
  UNION SELECT a->>'floor' FROM jsonb_array_elements(source->'assignments') a
 ) codes WHERE nullif(floor,'') IS NOT NULL ON CONFLICT(restaurant_id,stored_code) DO NOTHING;
 INSERT INTO public.store_service_stations(restaurant_id,code,kind,area_id)
 SELECT p_store_id,'legacy:'||x.kind||coalesce(':'||x.floor,''),x.kind,a.id
 FROM (SELECT DISTINCT e->>'kind' kind,e->>'floor' floor FROM jsonb_array_elements(source->'assignments')e)x
 LEFT JOIN public.store_service_areas a ON a.restaurant_id=p_store_id AND a.stored_code=x.floor
 ON CONFLICT(restaurant_id,code) DO NOTHING;
 next_version:=profile.revision+1;
 INSERT INTO public.store_operating_versions(restaurant_id,version_no,source_hash,legacy_workflow,fulfillment_mode,created_by)
 VALUES(p_store_id,next_version,captured_hash,source->>'workflow',source->>'fulfillment_mode',auth.uid()) RETURNING id INTO version_id;
 INSERT INTO public.store_operating_version_stations(restaurant_id,version_id,station_id)
 SELECT DISTINCT p_store_id,version_id,s.id FROM jsonb_array_elements(source->'assignments')e
 JOIN public.store_service_stations s ON s.restaurant_id=p_store_id
  AND s.code='legacy:'||(e->>'kind')||coalesce(':'||(e->>'floor'),'');
 INSERT INTO public.store_operating_version_assignments(restaurant_id,version_id,station_id,user_id,legacy_assignment_id)
 SELECT p_store_id,version_id,s.id,(e->>'user_id')::uuid,(e->>'id')::uuid
 FROM jsonb_array_elements(source->'assignments')e JOIN public.store_service_stations s ON s.restaurant_id=p_store_id
  AND s.code='legacy:'||(e->>'kind')||coalesce(':'||(e->>'floor'),'');
 UPDATE public.store_operating_profiles SET baseline_version_id=version_id,revision=next_version,updated_at=now()
 WHERE restaurant_id=p_store_id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'store_operating_baseline_captured','restaurants',p_store_id,
  jsonb_build_object('version_id',version_id,'revision',next_version,'source_hash',captured_hash,'runtime_authority','legacy'));
 RETURN public.admin_get_store_operating_profile_v1(p_store_id);
END;
$$;

-- Immutable baseline records cannot be rewritten even through an accidental
-- future owner-side UPDATE. Only the current pointer is mutable.
CREATE FUNCTION public.store_operating_immutable_v1() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'OPERATING_PROFILE_IMMUTABLE'; END;
$$;
CREATE TRIGGER operating_version_immutable BEFORE UPDATE OR DELETE ON public.store_operating_versions
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_membership_immutable BEFORE UPDATE OR DELETE ON public.store_operating_version_stations
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_assignment_immutable BEFORE UPDATE OR DELETE ON public.store_operating_version_assignments
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_area_immutable BEFORE UPDATE OR DELETE ON public.store_service_areas
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_station_immutable BEFORE UPDATE OR DELETE ON public.store_service_stations
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
REVOKE ALL ON FUNCTION public.store_operating_immutable_v1() FROM PUBLIC,anon,authenticated,service_role;

ALTER TABLE public.store_service_areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_service_stations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_operating_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_operating_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_operating_version_stations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_operating_version_assignments ENABLE ROW LEVEL SECURITY;
-- Access is intentionally through the scoped admin RPC. No default table grants.
REVOKE ALL ON public.store_service_areas,public.store_service_stations,
 public.store_operating_profiles,public.store_operating_versions,
 public.store_operating_version_stations,public.store_operating_version_assignments FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_get_store_operating_profile_v1(uuid),
 public.admin_capture_store_operating_baseline_v1(uuid,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_operating_profile_v1(uuid),
 public.admin_capture_store_operating_baseline_v1(uuid,bigint) TO authenticated,service_role;

DO $$ BEGIN
 IF has_function_privilege('anon','public.admin_get_store_operating_profile_v1(uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.store_operating_source_v1(uuid)','EXECUTE')
 OR has_table_privilege('authenticated','public.store_operating_versions','INSERT') THEN
  RAISE EXCEPTION 'OPERATING_PROFILE_ACCESS_INVALID'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
