-- Office integration Phase 2: Payroll auto-review creation trigger

CREATE TABLE IF NOT EXISTS office_payroll_reviews (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_payroll_id UUID NOT NULL REFERENCES payroll_records(id),
  restaurant_id     UUID NOT NULL REFERENCES restaurants(id),
  brand_id          UUID REFERENCES brands(id),
  period_start      DATE NOT NULL,
  period_end        DATE NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending_review'
                      CHECK (status IN (
                        'pending_review','in_review','confirmed','rejected','returned'
                      )),
  reviewed_by       UUID REFERENCES auth.users(id),
  confirmed_by      UUID REFERENCES auth.users(id),
  review_notes      TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uniq_office_payroll_review
    UNIQUE (source_payroll_id, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS idx_office_payroll_reviews_restaurant
  ON office_payroll_reviews(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_office_payroll_reviews_brand
  ON office_payroll_reviews(brand_id);
CREATE INDEX IF NOT EXISTS idx_office_payroll_reviews_status
  ON office_payroll_reviews(status);

ALTER TABLE office_payroll_reviews ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_payroll_reviews'
      AND policyname = 'office_payroll_reviews_authenticated_select'
  ) THEN
    CREATE POLICY office_payroll_reviews_authenticated_select
    ON office_payroll_reviews
    FOR SELECT
    TO authenticated
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'office_payroll_reviews'
      AND policyname = 'office_payroll_reviews_admin_update'
  ) THEN
    CREATE POLICY office_payroll_reviews_admin_update
    ON office_payroll_reviews
    FOR UPDATE
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM users u
        WHERE u.auth_id = auth.uid()
          AND u.role IN ('admin', 'super_admin')
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1
        FROM users u
        WHERE u.auth_id = auth.uid()
          AND u.role IN ('admin', 'super_admin')
      )
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION on_payroll_store_submitted()
RETURNS TRIGGER AS $$
DECLARE
  v_brand_id UUID;
BEGIN
  SELECT brand_id
  INTO v_brand_id
  FROM restaurants
  WHERE id = NEW.restaurant_id;

  INSERT INTO office_payroll_reviews (
    source_payroll_id,
    restaurant_id,
    brand_id,
    period_start,
    period_end,
    status
  )
  VALUES (
    NEW.id,
    NEW.restaurant_id,
    v_brand_id,
    NEW.period_start,
    NEW.period_end,
    'pending_review'
  )
  ON CONFLICT (source_payroll_id, period_start, period_end) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_payroll_store_submitted ON payroll_records;
CREATE TRIGGER trg_payroll_store_submitted
AFTER UPDATE OF status ON payroll_records
FOR EACH ROW
WHEN (NEW.status = 'store_submitted' AND OLD.status = 'draft')
EXECUTE FUNCTION on_payroll_store_submitted();
