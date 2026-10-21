-- Keep the existing inactive-store purge contract after baseline capture.
-- Baselines remain immutable while their parent store exists. Only a real
-- parent deletion can cascade; no client-set flag bypasses immutability.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

ALTER TABLE public.store_service_areas
 DROP CONSTRAINT store_service_areas_restaurant_id_fkey,
 ADD CONSTRAINT store_service_areas_restaurant_id_fkey
 FOREIGN KEY(restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;
ALTER TABLE public.store_service_stations
 DROP CONSTRAINT store_service_stations_restaurant_id_fkey,
 ADD CONSTRAINT store_service_stations_restaurant_id_fkey
 FOREIGN KEY(restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;
ALTER TABLE public.store_service_stations
 DROP CONSTRAINT store_service_stations_restaurant_id_area_id_fkey,
 ADD CONSTRAINT store_service_stations_restaurant_id_area_id_fkey
 FOREIGN KEY(restaurant_id,area_id) REFERENCES public.store_service_areas(restaurant_id,id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_versions
 DROP CONSTRAINT store_operating_versions_restaurant_id_fkey,
 ADD CONSTRAINT store_operating_versions_restaurant_id_fkey
 FOREIGN KEY(restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_profiles
 DROP CONSTRAINT store_operating_profiles_restaurant_id_fkey,
 ADD CONSTRAINT store_operating_profiles_restaurant_id_fkey
 FOREIGN KEY(restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_profiles
 DROP CONSTRAINT store_operating_profiles_restaurant_id_baseline_version_id_fkey,
 ADD CONSTRAINT store_operating_profiles_restaurant_id_baseline_version_id_fkey
 FOREIGN KEY(restaurant_id,baseline_version_id) REFERENCES public.store_operating_versions(restaurant_id,id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_version_stations
 DROP CONSTRAINT store_operating_version_stations_restaurant_id_version_id_fkey,
 ADD CONSTRAINT store_operating_version_stations_restaurant_id_version_id_fkey
 FOREIGN KEY(restaurant_id,version_id) REFERENCES public.store_operating_versions(restaurant_id,id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_version_stations
 DROP CONSTRAINT store_operating_version_stations_restaurant_id_station_id_fkey,
 ADD CONSTRAINT store_operating_version_stations_restaurant_id_station_id_fkey
 FOREIGN KEY(restaurant_id,station_id) REFERENCES public.store_service_stations(restaurant_id,id) ON DELETE CASCADE;
ALTER TABLE public.store_operating_version_assignments
 DROP CONSTRAINT store_operating_version_assig_restaurant_id_version_id_sta_fkey,
 ADD CONSTRAINT store_operating_version_assig_restaurant_id_version_id_sta_fkey
 FOREIGN KEY(restaurant_id,version_id,station_id)
 REFERENCES public.store_operating_version_stations(restaurant_id,version_id,station_id) ON DELETE CASCADE;

-- A transition table checks the entire deleted set, avoiding a lookup for
-- every baseline/assignment. A direct deletion rolls back even for an owner.
CREATE FUNCTION public.store_operating_guard_delete_v1() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM deleted_operating_rows d JOIN public.restaurants r ON r.id=d.restaurant_id) THEN
  RAISE EXCEPTION 'OPERATING_PROFILE_IMMUTABLE';
 END IF;
 RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.store_operating_guard_delete_v1() FROM PUBLIC,anon,authenticated,service_role;

DROP TRIGGER operating_version_immutable ON public.store_operating_versions;
CREATE TRIGGER operating_version_immutable BEFORE UPDATE ON public.store_operating_versions
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_version_delete_guard AFTER DELETE ON public.store_operating_versions
 REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();
DROP TRIGGER operating_membership_immutable ON public.store_operating_version_stations;
CREATE TRIGGER operating_membership_immutable BEFORE UPDATE ON public.store_operating_version_stations
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_membership_delete_guard AFTER DELETE ON public.store_operating_version_stations
 REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();
DROP TRIGGER operating_assignment_immutable ON public.store_operating_version_assignments;
CREATE TRIGGER operating_assignment_immutable BEFORE UPDATE ON public.store_operating_version_assignments
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_assignment_delete_guard AFTER DELETE ON public.store_operating_version_assignments
 REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();
DROP TRIGGER operating_area_immutable ON public.store_service_areas;
CREATE TRIGGER operating_area_immutable BEFORE UPDATE ON public.store_service_areas
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_area_delete_guard AFTER DELETE ON public.store_service_areas
 REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();
DROP TRIGGER operating_station_immutable ON public.store_service_stations;
CREATE TRIGGER operating_station_immutable BEFORE UPDATE ON public.store_service_stations
 FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER operating_station_delete_guard AFTER DELETE ON public.store_service_stations
 REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();

DO $$ BEGIN
 IF has_function_privilege('authenticated','public.store_operating_guard_delete_v1()','EXECUTE')
 OR has_table_privilege('authenticated','public.store_operating_versions','DELETE')
 OR NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.store_operating_versions'::regclass
  AND conname='store_operating_versions_restaurant_id_fkey' AND confdeltype='c') THEN
  RAISE EXCEPTION 'OPERATING_PROFILE_PURGE_CONTRACT_INVALID';
 END IF;
END $$;
COMMIT;
