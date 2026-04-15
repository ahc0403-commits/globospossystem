-- Migrated from restaurant_office_app. RLS added.

CREATE TABLE IF NOT EXISTS public.office_qc_followups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_qc_check_id uuid NOT NULL REFERENCES public.qc_checks(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  brand_id uuid NOT NULL REFERENCES public.brands(id),
  status text NOT NULL CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),
  assigned_to uuid,
  resolution_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
ALTER TABLE public.office_qc_followups ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_qc_followups'
      AND policyname = 'office_qc_followups_authenticated_select'
  ) THEN
    CREATE POLICY office_qc_followups_authenticated_select
    ON public.office_qc_followups
    FOR SELECT
    TO authenticated
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_qc_followups'
      AND policyname = 'office_qc_followups_authenticated_insert'
  ) THEN
    CREATE POLICY office_qc_followups_authenticated_insert
    ON public.office_qc_followups
    FOR INSERT
    TO authenticated
    WITH CHECK (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_qc_followups'
      AND policyname = 'office_qc_followups_authenticated_update'
  ) THEN
    CREATE POLICY office_qc_followups_authenticated_update
    ON public.office_qc_followups
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);
  END IF;
END $$;
