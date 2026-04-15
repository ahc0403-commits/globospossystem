-- Office integration Phase 2: Payroll bidirectional RPC

CREATE TABLE IF NOT EXISTS audit_logs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    UUID REFERENCES auth.users(id),
  action      TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   UUID,
  details     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity
  ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
  ON audit_logs(created_at DESC);
CREATE OR REPLACE FUNCTION office_confirm_payroll(p_payroll_id UUID)
RETURNS payroll_records AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT *
  INTO v_payroll
  FROM payroll_records
  WHERE id = p_payroll_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYROLL_NOT_FOUND';
  END IF;

  IF v_payroll.status <> 'store_submitted' THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION';
  END IF;

  UPDATE payroll_records
  SET status = 'office_confirmed',
      updated_at = now()
  WHERE id = p_payroll_id
  RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'office_confirm_payroll',
    'payroll_records',
    p_payroll_id,
    jsonb_build_object(
      'from_status', 'store_submitted',
      'to_status', 'office_confirmed'
    )
  );

  RETURN v_payroll;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
CREATE OR REPLACE FUNCTION office_return_payroll(p_payroll_id UUID)
RETURNS payroll_records AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT *
  INTO v_payroll
  FROM payroll_records
  WHERE id = p_payroll_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYROLL_NOT_FOUND';
  END IF;

  IF v_payroll.status <> 'store_submitted' THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION';
  END IF;

  UPDATE payroll_records
  SET status = 'draft',
      updated_at = now()
  WHERE id = p_payroll_id
  RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'office_return_payroll',
    'payroll_records',
    p_payroll_id,
    jsonb_build_object(
      'from_status', 'store_submitted',
      'to_status', 'draft'
    )
  );

  RETURN v_payroll;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
