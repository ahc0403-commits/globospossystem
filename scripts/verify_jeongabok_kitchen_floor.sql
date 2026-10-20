DO $$
BEGIN
  IF NOT public.kds_is_direct_floor_store('273b057e-3b69-46e3-93c1-6194c2802849')
    OR public.kds_is_direct_floor_store('8bc9eef5-dcd5-46b1-b931-23f77132322c')
    OR public.kds_is_direct_floor_store('3a268807-771f-4fd4-84fe-e1b0b00de40a') THEN
    RAISE EXCEPTION 'KDS_DIRECT_STORE_SCOPE_FAILED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE public.kds_is_direct_floor_store(restaurant_id)
      AND fixed_account_code ~ '_(tray1|tray)$' AND is_active)
    OR EXISTS (SELECT 1 FROM public.emergency_station_assignments
      WHERE public.kds_is_direct_floor_store(restaurant_id) AND station_type='tray' AND is_active)
    OR EXISTS (SELECT 1 FROM public.store_fixed_account_requirements
      WHERE public.kds_is_direct_floor_store(store_id) AND account_code ~ '_(tray1|tray)$' AND is_active)
    OR EXISTS (SELECT 1 FROM public.emergency_web_push_devices d JOIN public.emergency_station_assignments a
      ON a.id=d.station_assignment_id WHERE public.kds_is_direct_floor_store(a.restaurant_id)
      AND a.station_type='tray' AND d.is_enabled) THEN
    RAISE EXCEPTION 'JEONGABOK_CHECKER_RETIREMENT_FAILED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users u JOIN auth.users a ON a.id=u.auth_id
    WHERE public.kds_is_direct_floor_store(u.restaurant_id) AND u.fixed_account_code ~ '_(tray1|tray)$'
      AND (a.banned_until IS NULL OR a.banned_until<=now())) THEN
    RAISE EXCEPTION 'JEONGABOK_CHECKER_AUTH_NOT_DISABLED';
  END IF;
  IF (SELECT count(*) FROM public.emergency_station_assignments WHERE public.kds_is_direct_floor_store(restaurant_id)
    AND station_type='floor' AND is_active AND floor_label IN ('1F','2F','3F')) <> 3 THEN
    RAISE EXCEPTION 'JEONGABOK_FLOOR_ASSIGNMENTS_CHANGED';
  END IF;
  IF public.emergency_floor_label('273b057e-3b69-46e3-93c1-6194c2802849','3F','2212') <> '3F'
    OR public.emergency_floor_label('8bc9eef5-dcd5-46b1-b931-23f77132322c','3F','2212') <> '2F' THEN
    RAISE EXCEPTION 'KDS_FLOOR_ROUTING_REGRESSION';
  END IF;
END;
$$;
SELECT 'JEONGABOK_KITCHEN_FLOOR_VERIFY=PASS';
