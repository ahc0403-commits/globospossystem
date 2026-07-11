DO $assert_replay$
BEGIN
  IF EXISTS (
    (TABLE test_expected.object_backup EXCEPT TABLE public.hierarchy_20260711090000_object_backup)
    UNION ALL
    (TABLE public.hierarchy_20260711090000_object_backup EXCEPT TABLE test_expected.object_backup)
  ) OR EXISTS (
    (TABLE test_expected.photo_backup EXCEPT TABLE public.hierarchy_20260711090000_photo_backup)
    UNION ALL
    (TABLE public.hierarchy_20260711090000_photo_backup EXCEPT TABLE test_expected.photo_backup)
  ) OR EXISTS (
    (TABLE test_expected.history_backup EXCEPT TABLE public.hierarchy_20260711090000_history_backup)
    UNION ALL
    (TABLE public.hierarchy_20260711090000_history_backup EXCEPT TABLE test_expected.history_backup)
  ) OR EXISTS (
    (TABLE test_expected.backup_state EXCEPT TABLE public.hierarchy_20260711090000_backup_state)
    UNION ALL
    (TABLE public.hierarchy_20260711090000_backup_state EXCEPT TABLE test_expected.backup_state)
  ) THEN
    RAISE EXCEPTION 'LOCAL_SMOKE_REPLAY_MUTATED_BACKUP';
  END IF;
END;
$assert_replay$;
