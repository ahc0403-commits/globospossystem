-- Migrated from restaurant_office_app. RLS added.

CREATE TABLE IF NOT EXISTS public.office_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  brand_id uuid REFERENCES public.brands(id),
  status text NOT NULL CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'returned')),
  title text NOT NULL,
  description text,
  total_amount numeric(12,2) NOT NULL,
  items jsonb,
  requested_by uuid,
  approved_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.office_purchases ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_purchases'
      AND policyname = 'office_purchases_authenticated_select'
  ) THEN
    CREATE POLICY office_purchases_authenticated_select
    ON public.office_purchases
    FOR SELECT
    TO authenticated
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_purchases'
      AND policyname = 'office_purchases_authenticated_insert'
  ) THEN
    CREATE POLICY office_purchases_authenticated_insert
    ON public.office_purchases
    FOR INSERT
    TO authenticated
    WITH CHECK (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_purchases'
      AND policyname = 'office_purchases_authenticated_update'
  ) THEN
    CREATE POLICY office_purchases_authenticated_update
    ON public.office_purchases
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);
  END IF;
END $$;
