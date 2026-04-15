-- Office integration Phase 0: Payroll status migration (BREAKING)

-- Pre-migration check: rows to be migrated
SELECT COUNT(*) AS confirmed_rows_before_migration
FROM payroll_records
WHERE status = 'confirmed';
-- Step 1: Remove existing CHECK constraint
ALTER TABLE payroll_records
  DROP CONSTRAINT IF EXISTS payroll_records_status_check;
-- Step 2: Migrate data (confirmed → store_submitted)
UPDATE payroll_records
  SET status = 'store_submitted'
  WHERE status = 'confirmed';
-- Step 3: Add new CHECK constraint with expanded values
ALTER TABLE payroll_records
  ADD CONSTRAINT payroll_records_status_check
  CHECK (status IN ('draft', 'store_submitted', 'office_confirmed', 'paid'));
-- Post-migration verification
DO $$
DECLARE
  old_count INT;
  new_count INT;
BEGIN
  SELECT COUNT(*) INTO old_count FROM payroll_records WHERE status = 'confirmed';
  SELECT COUNT(*) INTO new_count FROM payroll_records WHERE status = 'store_submitted';
  IF old_count > 0 THEN
    RAISE EXCEPTION 'Migration failed: % rows still have status=confirmed', old_count;
  END IF;
  RAISE NOTICE 'Migration successful: % rows now have status=store_submitted', new_count;
END $$;
