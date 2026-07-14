-- Repair the deployed Photo Objet backup/control-plane boundary. The initial
-- migrations now create these tables securely; this forward migration closes
-- the same boundary for environments where those versions already ran.

DO $preflight$
DECLARE
  v_invalid text;
BEGIN
  WITH required(table_name) AS (
    VALUES
      ('photo_interval_20260712190000_jobs_backup'),
      ('photo_interval_20260712190000_raw_backup'),
      ('photo_interval_20260712190000_runs_backup'),
      ('photo_interval_20260712190000_sales_backup'),
      ('photo_interval_20260712190000_state'),
      ('photo_slot_20260713120000_state')
  )
  SELECT string_agg(required.table_name, ', ' ORDER BY required.table_name)
  INTO v_invalid
  FROM required
  LEFT JOIN pg_catalog.pg_class relation
    ON relation.relnamespace = 'public'::regnamespace
   AND relation.relname = required.table_name
   AND relation.relkind IN ('r', 'p')
  WHERE relation.oid IS NULL;

  IF v_invalid IS NOT NULL THEN
    RAISE EXCEPTION
      'PHOTO_OBJET_BACKUP_SECURITY_TARGET_MISSING_OR_INVALID: %',
      v_invalid;
  END IF;
END
$preflight$;

ALTER TABLE public.photo_interval_20260712190000_jobs_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_jobs_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_raw_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_raw_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_runs_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_runs_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_sales_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_sales_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_state
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_state
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260713120000_state
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260713120000_state
  FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.photo_interval_20260712190000_jobs_backup,
  public.photo_interval_20260712190000_raw_backup,
  public.photo_interval_20260712190000_runs_backup,
  public.photo_interval_20260712190000_sales_backup,
  public.photo_interval_20260712190000_state,
  public.photo_slot_20260713120000_state
FROM PUBLIC, anon, authenticated, service_role;
