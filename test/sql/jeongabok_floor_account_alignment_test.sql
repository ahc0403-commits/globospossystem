CREATE TRIGGER sync_user_station AFTER INSERT OR UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.sync_emergency_station_assignment_for_user();
-- A profile update must not silently restore the broken account-floor mapping.
UPDATE public.users SET is_active=true WHERE id::text LIKE '80000000%';
DO $$ BEGIN
 IF (SELECT floor_label FROM public.emergency_station_assignments WHERE user_id='80000000-0000-4000-8000-000000000001')<>'2F'
 OR (SELECT floor_label FROM public.emergency_station_assignments WHERE user_id='80000000-0000-4000-8000-000000000002')<>'3F'
 OR (SELECT floor_label FROM public.emergency_station_assignments WHERE user_id='80000000-0000-4000-8000-000000000003')<>'1F'
 THEN RAISE EXCEPTION 'FLOOR_ACCOUNT_PROFILE_UPDATE_REGRESSION'; END IF;
 IF NOT (SELECT floor_direct_beverages_enabled FROM public.restaurant_settings WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849')
 OR (SELECT floor_direct_beverages_enabled FROM public.restaurant_settings WHERE restaurant_id='90000000-0000-4000-8000-000000000001')
 THEN RAISE EXCEPTION 'DRINK_GATE_STORE_SCOPE_REGRESSION'; END IF;
 IF has_function_privilege('anon','public.sync_emergency_station_assignment_for_user()','EXECUTE') THEN RAISE EXCEPTION 'PUBLIC_ACCOUNT_MUTATION_EXPOSED'; END IF;
END $$;
SELECT 'JEONGABOK_FLOOR_ACCOUNT_ALIGNMENT_SQL=PASS';
