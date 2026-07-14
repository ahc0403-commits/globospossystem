\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_invalid text;
  v_unprotected text;
  v_role_privileges text;
  v_public_privileges text;
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

  WITH required(table_name) AS (
    VALUES
      ('photo_interval_20260712190000_jobs_backup'),
      ('photo_interval_20260712190000_raw_backup'),
      ('photo_interval_20260712190000_runs_backup'),
      ('photo_interval_20260712190000_sales_backup'),
      ('photo_interval_20260712190000_state'),
      ('photo_slot_20260713120000_state')
  )
  SELECT string_agg(relation.relname, ', ' ORDER BY relation.relname)
  INTO v_unprotected
  FROM required
  JOIN pg_catalog.pg_class relation
    ON relation.relnamespace = 'public'::regnamespace
   AND relation.relname = required.table_name
  WHERE NOT relation.relrowsecurity OR NOT relation.relforcerowsecurity;

  IF v_unprotected IS NOT NULL THEN
    RAISE EXCEPTION
      'PHOTO_OBJET_BACKUP_SECURITY_RLS_NOT_FORCED: %', v_unprotected;
  END IF;

  WITH required(table_name) AS (
    VALUES
      ('photo_interval_20260712190000_jobs_backup'),
      ('photo_interval_20260712190000_raw_backup'),
      ('photo_interval_20260712190000_runs_backup'),
      ('photo_interval_20260712190000_sales_backup'),
      ('photo_interval_20260712190000_state'),
      ('photo_slot_20260713120000_state')
  ), blocked_role(role_name) AS (
    VALUES ('anon'), ('authenticated'), ('service_role')
  ), blocked_privilege(privilege_name) AS (
    VALUES
      ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'),
      ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')
  )
  SELECT string_agg(
    format('%s:%s:%s', required.table_name, blocked_role.role_name,
      blocked_privilege.privilege_name),
    ', ' ORDER BY required.table_name, blocked_role.role_name,
      blocked_privilege.privilege_name
  )
  INTO v_role_privileges
  FROM required
  CROSS JOIN blocked_role
  CROSS JOIN blocked_privilege
  WHERE pg_catalog.has_table_privilege(
    blocked_role.role_name,
    format('public.%I', required.table_name),
    blocked_privilege.privilege_name
  );

  IF v_role_privileges IS NOT NULL THEN
    RAISE EXCEPTION
      'PHOTO_OBJET_BACKUP_SECURITY_ROLE_PRIVILEGE_PRESENT: %',
      v_role_privileges;
  END IF;

  WITH required(table_name) AS (
    VALUES
      ('photo_interval_20260712190000_jobs_backup'),
      ('photo_interval_20260712190000_raw_backup'),
      ('photo_interval_20260712190000_runs_backup'),
      ('photo_interval_20260712190000_sales_backup'),
      ('photo_interval_20260712190000_state'),
      ('photo_slot_20260713120000_state')
  )
  SELECT string_agg(
    format('%s:%s', relation.relname, acl.privilege_type),
    ', ' ORDER BY relation.relname, acl.privilege_type
  )
  INTO v_public_privileges
  FROM required
  JOIN pg_catalog.pg_class relation
    ON relation.relnamespace = 'public'::regnamespace
   AND relation.relname = required.table_name
  CROSS JOIN LATERAL pg_catalog.aclexplode(
    coalesce(
      relation.relacl,
      pg_catalog.acldefault('r', relation.relowner)
    )
  ) acl
  WHERE acl.grantee = 0
    AND acl.privilege_type IN (
      'SELECT', 'INSERT', 'UPDATE', 'DELETE',
      'TRUNCATE', 'REFERENCES', 'TRIGGER'
    );

  IF v_public_privileges IS NOT NULL THEN
    RAISE EXCEPTION
      'PHOTO_OBJET_BACKUP_SECURITY_PUBLIC_PRIVILEGE_PRESENT: %',
      v_public_privileges;
  END IF;
END
$verify$;

SELECT 'PHOTO_OBJET_BACKUP_SECURITY_VERIFY_OK' AS result;
