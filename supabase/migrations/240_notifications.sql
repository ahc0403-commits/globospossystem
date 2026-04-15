-- Migration: 240_notifications.sql
-- In-app notification table for office users

CREATE TABLE IF NOT EXISTS system.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL,  -- office_user_profiles.auth_id
  type text NOT NULL CHECK (type IN (
    'payroll_pending', 'payroll_confirmed', 'payroll_rejected',
    'purchase_pending', 'purchase_approved', 'purchase_rejected',
    'quality_issue', 'quality_resolved',
    'document_released', 'account_created'
  )),
  title text NOT NULL,
  body text,
  entity_type text,  -- 'payroll', 'purchase', 'quality', 'document'
  entity_id uuid,
  is_read boolean DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_recipient
  ON system.notifications(recipient_id, is_read, created_at DESC);
ALTER TABLE system.notifications ENABLE ROW LEVEL SECURITY;
-- Users can only see and update their own notifications
CREATE POLICY notifications_own ON system.notifications
  FOR ALL TO authenticated
  USING (recipient_id = auth.uid())
  WITH CHECK (recipient_id = auth.uid());
-- Grant PostgREST access
GRANT USAGE ON SCHEMA system TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON system.notifications TO authenticated;
-- ────────────────────────────────────────────────────────────────────────────
-- Trigger: notify on payroll confirmation
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION system.notify_payroll_confirmed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status = 'confirmed' AND (OLD.status IS NULL OR OLD.status != 'confirmed') THEN
    INSERT INTO system.notifications (recipient_id, type, title, entity_type, entity_id)
    SELECT oup.auth_id,
           'payroll_confirmed',
           'Payroll record confirmed',
           'payroll',
           NEW.id
    FROM public.office_user_profiles oup
    WHERE oup.account_level IN ('super_admin', 'brand_admin')
      AND oup.is_active = true;
  END IF;
  RETURN NEW;
END; $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_payroll_confirmed'
  ) THEN
    CREATE TRIGGER trg_notify_payroll_confirmed
      AFTER UPDATE ON hr.payroll_records
      FOR EACH ROW EXECUTE FUNCTION system.notify_payroll_confirmed();
  END IF;
END; $$;
-- ────────────────────────────────────────────────────────────────────────────
-- Trigger: notify on document release
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION system.notify_document_released()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status = 'active' AND (OLD.status IS NULL OR OLD.status != 'active') THEN
    INSERT INTO system.notifications (recipient_id, type, title, entity_type, entity_id)
    SELECT oup.auth_id,
           'document_released',
           'Document released: ' || NEW.title,
           'document',
           NEW.id
    FROM public.office_user_profiles oup
    WHERE oup.is_active = true;
  END IF;
  RETURN NEW;
END; $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_document_released'
  ) THEN
    CREATE TRIGGER trg_notify_document_released
      AFTER UPDATE ON documents.documents
      FOR EACH ROW EXECUTE FUNCTION system.notify_document_released();
  END IF;
END; $$;
