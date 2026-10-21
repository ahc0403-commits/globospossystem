-- Owner confirmed: guest 1F jgbt_floor_1f; guest 2F jgbt_floor_2f.
-- Keep table floors, UUIDs, prices and real fulfillment quantities unchanged.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE OR REPLACE FUNCTION public.sync_emergency_station_assignment_for_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_station text;
  v_floor text;
BEGIN
  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.fixed_account_code ~ '_(tray1|tray)$' THEN
    v_station := 'tray';
  ELSIF NEW.fixed_account_code ~ '_(floor_1f|1f)$' THEN
    v_station := 'floor';
    v_floor := '1F';
  ELSIF NEW.fixed_account_code ~ '_(floor_[23]f|[23]f)$' THEN
    v_station := 'floor';
    v_floor := upper(substring(NEW.fixed_account_code from '([23]f)$'));
  ELSIF NEW.fixed_account_code ~ '_(kit1|kit)$' THEN
    v_station := 'kitchen';
  ELSE
    RETURN NEW;
  END IF;

  -- JeonGabok account names use guest-facing floors, while table UUIDs keep
  -- the historical stored 2F/3F labels (display 1F/2F).
  IF public.kds_is_direct_floor_store(NEW.restaurant_id) AND v_station='floor' THEN
    IF NEW.fixed_account_code ~ '_(floor_1f|1f)$' THEN v_floor:='2F';
    ELSIF NEW.fixed_account_code ~ '_(floor_2f|2f)$' THEN v_floor:='3F'; END IF;
  END IF;

  INSERT INTO public.emergency_station_assignments (
    restaurant_id, user_id, station_type, floor_label, is_active
  ) VALUES (
    NEW.restaurant_id, NEW.id, v_station, v_floor, NEW.is_active
  )
  ON CONFLICT (restaurant_id, user_id) DO UPDATE SET
    station_type = EXCLUDED.station_type,
    floor_label = EXCLUDED.floor_label,
    is_active = EXCLUDED.is_active,
    updated_at = now();

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_emergency_station_assignment_for_user() FROM PUBLIC,anon,authenticated;
UPDATE public.emergency_station_assignments a
SET floor_label=CASE WHEN u.fixed_account_code ~ '_(floor_1f|1f)$' THEN '2F' ELSE '3F' END,updated_at=now()
FROM public.users u WHERE u.id=a.user_id AND u.restaurant_id=a.restaurant_id
 AND public.kds_is_direct_floor_store(a.restaurant_id) AND a.station_type='floor'
 AND u.fixed_account_code ~ '_(floor_[12]f|[12]f)$'
 AND a.floor_label IS DISTINCT FROM CASE WHEN u.fixed_account_code ~ '_(floor_1f|1f)$' THEN '2F' ELSE '3F' END;
UPDATE public.restaurant_settings SET floor_direct_beverages_enabled=true,updated_at=now()
WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT floor_direct_beverages_enabled;
INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
VALUES(NULL,'jeongabok_floor_account_alignment_release','restaurants','273b057e-3b69-46e3-93c1-6194c2802849',
 jsonb_build_object('owner_confirmed_accounts','1F: jgbt_floor_1f / 2F: jgbt_floor_2f',
 'operator','Codex maintenance','table_labels_changed',false,'service_quantities_changed',false));
SELECT public.kds_append_change(s.restaurant_id,s.id,gen_random_uuid(),'bootstrap_required',
 ARRAY['kitchen','floor'],NULL,NULL,NULL,NULL,jsonb_build_object('kind','bootstrap_required','reason','floor_account_alignment'),
 'floor-account-alignment:20261021120000') FROM public.emergency_fulfillment_sessions s
WHERE public.kds_is_direct_floor_store(s.restaurant_id) AND s.status='active';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id
 WHERE public.kds_is_direct_floor_store(a.restaurant_id) AND u.restaurant_id=a.restaurant_id
 AND a.station_type='floor' AND u.fixed_account_code ~ '_(floor_[12]f|[12]f)$'
 AND a.floor_label IS DISTINCT FROM CASE WHEN u.fixed_account_code ~ '_(floor_1f|1f)$' THEN '2F' ELSE '3F' END)
 OR EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT floor_direct_beverages_enabled)
 THEN RAISE EXCEPTION 'JEONGABOK_FLOOR_ACCOUNT_ALIGNMENT_FAILED'; END IF;
END $$;
COMMIT;
