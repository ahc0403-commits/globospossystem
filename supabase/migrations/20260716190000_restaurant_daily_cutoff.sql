-- Restaurant is an explicit operational classification. Absence from this
-- table is the safe default and leaves Photo and every other store unchanged.
CREATE TABLE IF NOT EXISTS public.restaurant_cutoff_policies (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.restaurant_cutoff_policies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS restaurant_cutoff_policies_scoped_read
  ON public.restaurant_cutoff_policies;
CREATE POLICY restaurant_cutoff_policies_scoped_read
  ON public.restaurant_cutoff_policies
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) scoped(store_id)
      WHERE scoped.store_id = restaurant_cutoff_policies.restaurant_id
    )
  );

REVOKE ALL ON public.restaurant_cutoff_policies FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.restaurant_cutoff_policies TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.restaurant_daily_sales_finalizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_date date NOT NULL,
  status text NOT NULL CHECK (status IN ('finalized', 'data_integrity_failed')),
  store_count integer NOT NULL DEFAULT 0 CHECK (store_count >= 0),
  receipt_count integer CHECK (receipt_count IS NULL OR receipt_count >= 0),
  gross_sales numeric(18,2) CHECK (gross_sales IS NULL OR gross_sales >= 0),
  post_cutoff_receipt_count integer NOT NULL DEFAULT 0
    CHECK (post_cutoff_receipt_count >= 0),
  offending_stores jsonb NOT NULL DEFAULT '[]'::jsonb,
  observed_at timestamptz NOT NULL,
  finalized_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT restaurant_daily_sales_finalizations_business_date_key
    UNIQUE (business_date),
  CONSTRAINT restaurant_daily_sales_finalizations_offenders_array_check
    CHECK (jsonb_typeof(offending_stores) = 'array')
);

ALTER TABLE public.restaurant_daily_sales_finalizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_daily_sales_finalizations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.restaurant_daily_sales_finalizations
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.restaurant_daily_sales_finalizations TO service_role;

CREATE OR REPLACE FUNCTION public.enforce_restaurant_finalization_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = 'P0001',
    MESSAGE = 'RESTAURANT_FINALIZATION_IMMUTABLE';
END;
$$;

DROP TRIGGER IF EXISTS trg_restaurant_finalization_immutable
  ON public.restaurant_daily_sales_finalizations;
CREATE TRIGGER trg_restaurant_finalization_immutable
BEFORE UPDATE OR DELETE ON public.restaurant_daily_sales_finalizations
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_finalization_immutable();

CREATE OR REPLACE FUNCTION public.restaurant_cutoff_state_at(
  p_restaurant_id uuid,
  p_observed_at timestamptz
) RETURNS TABLE (
  is_restaurant boolean,
  phase text,
  can_create_order boolean,
  can_complete_payment boolean,
  business_date date,
  observed_at timestamptz
)
LANGUAGE plpgsql
STABLE
-- The invoker trigger must see explicit policy state even when table RLS hides
-- configuration rows. This helper returns cutoff state only, never sales data.
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_hcm_time time;
BEGIN
  IF p_restaurant_id IS NULL OR p_observed_at IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_CUTOFF_INPUT_REQUIRED';
  END IF;

  is_restaurant := EXISTS (
    SELECT 1
    FROM public.restaurant_cutoff_policies policy
    WHERE policy.restaurant_id = p_restaurant_id
      AND policy.is_enabled = true
  );
  business_date := (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  observed_at := p_observed_at;
  v_hcm_time := (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;

  IF NOT is_restaurant THEN
    phase := 'not_applicable';
    can_create_order := true;
    can_complete_payment := true;
  ELSIF v_hcm_time >= TIME '21:45:00' THEN
    phase := 'sales_closed';
    can_create_order := false;
    can_complete_payment := false;
  ELSIF v_hcm_time >= TIME '21:30:00' THEN
    phase := 'kitchen_closed';
    can_create_order := false;
    can_complete_payment := true;
  ELSE
    phase := 'open';
    can_create_order := true;
    can_complete_payment := true;
  END IF;

  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.restaurant_assert_kitchen_mutation_allowed_at(
  p_restaurant_id uuid,
  p_observed_at timestamptz
) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_state record;
BEGIN
  SELECT * INTO STRICT v_state
  FROM public.restaurant_cutoff_state_at(p_restaurant_id, p_observed_at);

  IF v_state.phase = 'sales_closed' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_DAILY_SALES_CLOSED';
  END IF;
  IF v_state.phase = 'kitchen_closed' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_KITCHEN_CLOSED';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.restaurant_assert_payment_allowed_at(
  p_restaurant_id uuid,
  p_observed_at timestamptz
) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_state record;
BEGIN
  SELECT * INTO STRICT v_state
  FROM public.restaurant_cutoff_state_at(p_restaurant_id, p_observed_at);

  IF v_state.phase = 'sales_closed' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_DAILY_SALES_CLOSED';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_restaurant_cutoff_state(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_state record;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_CUTOFF_STORE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scoped(store_id)
       WHERE scoped.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_CUTOFF_FORBIDDEN';
  END IF;

  SELECT * INTO STRICT v_state
  FROM public.restaurant_cutoff_state_at(p_store_id, statement_timestamp());

  RETURN jsonb_build_object(
    'is_restaurant', v_state.is_restaurant,
    'phase', v_state.phase,
    'can_create_order', v_state.can_create_order,
    'can_complete_payment', v_state.can_complete_payment,
    'business_date', v_state.business_date,
    'observed_at', v_state.observed_at,
    'timezone', 'Asia/Ho_Chi_Minh',
    'kitchen_closes_at', '21:30:00',
    'sales_close_at', '21:45:00',
    'aggregation_at', '22:20:00'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_restaurant_daily_cutoff()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_observed_at timestamptz := statement_timestamp();
  v_state record;
  v_process_payment_owner text;
  v_is_payment_service_charge boolean := false;
BEGIN
  SELECT * INTO STRICT v_state
  FROM public.restaurant_cutoff_state_at(NEW.restaurant_id, v_observed_at);
  IF NOT v_state.is_restaurant THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'INSERT' THEN
      PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    ELSIF OLD.status IS DISTINCT FROM 'completed'
          AND NEW.status = 'completed' THEN
      PERFORM public.restaurant_assert_payment_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF v_state.phase = 'sales_closed' THEN
        PERFORM public.restaurant_assert_payment_allowed_at(
          NEW.restaurant_id,
          v_observed_at
        );
      END IF;

      SELECT pg_get_userbyid(proc.proowner)
      INTO v_process_payment_owner
      FROM pg_proc proc
      WHERE proc.oid = to_regprocedure(
        'public.process_payment(uuid,uuid,numeric,text)'
      );

      v_is_payment_service_charge :=
        NEW.item_type = 'service_charge'
        AND NEW.display_name IN (
          'Service Charge (Food)',
          'Service Charge (Alcohol)'
        )
        AND v_process_payment_owner IS NOT NULL
        AND current_user = v_process_payment_owner;

      IF v_state.phase = 'kitchen_closed'
         AND NOT v_is_payment_service_charge THEN
        PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
          NEW.restaurant_id,
          v_observed_at
        );
      END IF;
    ELSIF NEW.quantity > OLD.quantity
          OR NEW.unit_price > OLD.unit_price THEN
      PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    ELSIF v_state.phase = 'sales_closed'
          AND (
            (OLD.status = 'cancelled' AND NEW.status <> 'cancelled')
            OR COALESCE(NEW.paying_amount_inc_tax, 0)
               > COALESCE(OLD.paying_amount_inc_tax, 0)
          ) THEN
      PERFORM public.restaurant_assert_payment_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'payments' THEN
    IF TG_OP = 'INSERT' THEN
      PERFORM public.restaurant_assert_payment_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
      NEW.created_at := v_observed_at;
    ELSIF NEW.amount > OLD.amount
          OR (OLD.is_revenue IS DISTINCT FROM true AND NEW.is_revenue = true)
          OR NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      PERFORM public.restaurant_assert_payment_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'external_sales' THEN
    IF NEW.is_revenue = true
       AND NEW.order_status = 'completed'
       AND (
         TG_OP = 'INSERT'
         OR OLD.is_revenue IS DISTINCT FROM true
         OR OLD.order_status IS DISTINCT FROM 'completed'
         OR NEW.gross_amount > OLD.gross_amount
         OR NEW.completed_at IS DISTINCT FROM OLD.completed_at
       ) THEN
      PERFORM public.restaurant_assert_payment_allowed_at(
        NEW.restaurant_id,
        v_observed_at
      );
    END IF;
    IF TG_OP = 'INSERT' THEN
      NEW.created_at := v_observed_at;
    ELSE
      NEW.updated_at := v_observed_at;
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restaurant_cutoff_orders ON public.orders;
CREATE TRIGGER trg_restaurant_cutoff_orders
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_daily_cutoff();

DROP TRIGGER IF EXISTS trg_restaurant_cutoff_order_items ON public.order_items;
CREATE TRIGGER trg_restaurant_cutoff_order_items
BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_daily_cutoff();

DROP TRIGGER IF EXISTS trg_restaurant_cutoff_payments ON public.payments;
CREATE TRIGGER trg_restaurant_cutoff_payments
BEFORE INSERT OR UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_daily_cutoff();

DROP TRIGGER IF EXISTS trg_restaurant_cutoff_external_sales
  ON public.external_sales;
CREATE TRIGGER trg_restaurant_cutoff_external_sales
BEFORE INSERT OR UPDATE ON public.external_sales
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_daily_cutoff();

DROP VIEW IF EXISTS public.v_restaurant_sales_receipts;
CREATE VIEW public.v_restaurant_sales_receipts
WITH (security_invoker = true) AS
SELECT
  payment.restaurant_id AS store_id,
  payment.id::text AS receipt_id,
  'pos_payment'::text AS receipt_source,
  orders.sales_channel,
  payment.amount::numeric(18,2) AS gross_sales,
  payment.created_at AS sold_at,
  (payment.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date_hcm,
  date_trunc(
    'hour',
    payment.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
  ) AS sale_hour_hcm
FROM public.payments payment
JOIN public.orders orders ON orders.id = payment.order_id
JOIN public.restaurant_cutoff_policies policy
  ON policy.restaurant_id = payment.restaurant_id
 AND policy.is_enabled = true
WHERE payment.is_revenue = true
UNION ALL
SELECT
  external.restaurant_id AS store_id,
  external.id::text AS receipt_id,
  'external_delivery'::text AS receipt_source,
  external.sales_channel,
  external.gross_amount::numeric(18,2) AS gross_sales,
  COALESCE(external.completed_at, external.created_at) AS sold_at,
  (
    COALESCE(external.completed_at, external.created_at)
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  )::date AS sale_date_hcm,
  date_trunc(
    'hour',
    COALESCE(external.completed_at, external.created_at)
      AT TIME ZONE 'Asia/Ho_Chi_Minh'
  ) AS sale_hour_hcm
FROM public.external_sales external
JOIN public.restaurant_cutoff_policies policy
  ON policy.restaurant_id = external.restaurant_id
 AND policy.is_enabled = true
WHERE external.is_revenue = true
  AND external.order_status = 'completed';

REVOKE ALL ON public.v_restaurant_sales_receipts FROM PUBLIC, anon;
GRANT SELECT ON public.v_restaurant_sales_receipts TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.restaurant_finalize_daily_sales_at(
  p_business_date date,
  p_observed_at timestamptz
) RETURNS public.restaurant_daily_sales_finalizations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_existing public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_result public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_store_count integer := 0;
  v_receipt_count integer := 0;
  v_gross_sales numeric(18,2) := 0;
  v_post_cutoff_count integer := 0;
  v_offending_stores jsonb := '[]'::jsonb;
  v_hcm_date date;
  v_hcm_time time;
BEGIN
  IF p_business_date IS NULL OR p_observed_at IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_FINALIZATION_INPUT_REQUIRED';
  END IF;

  v_hcm_date := (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_hcm_time := (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;

  IF v_hcm_date <> p_business_date THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_FINALIZATION_DATE_INVALID';
  END IF;
  IF v_hcm_time < TIME '22:20:00' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_FINALIZATION_TOO_EARLY';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('restaurant-daily-sales:' || p_business_date::text)
  );

  SELECT * INTO v_existing
  FROM public.restaurant_daily_sales_finalizations finalization
  WHERE finalization.business_date = p_business_date;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT count(*) INTO v_store_count
  FROM public.restaurant_cutoff_policies policy
  WHERE policy.is_enabled = true;

  WITH receipts AS (
    SELECT
      payment.restaurant_id AS store_id,
      payment.id AS receipt_id,
      payment.amount::numeric(18,2) AS amount,
      payment.created_at AS sold_at
    FROM public.payments payment
    JOIN public.restaurant_cutoff_policies policy
      ON policy.restaurant_id = payment.restaurant_id
     AND policy.is_enabled = true
    WHERE payment.is_revenue = true
      AND (payment.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
          = p_business_date
    UNION ALL
    SELECT
      external.restaurant_id AS store_id,
      external.id AS receipt_id,
      external.gross_amount::numeric(18,2) AS amount,
      COALESCE(external.completed_at, external.created_at) AS sold_at
    FROM public.external_sales external
    JOIN public.restaurant_cutoff_policies policy
      ON policy.restaurant_id = external.restaurant_id
     AND policy.is_enabled = true
    WHERE external.is_revenue = true
      AND external.order_status = 'completed'
      AND (
        COALESCE(external.completed_at, external.created_at)
        AT TIME ZONE 'Asia/Ho_Chi_Minh'
      )::date = p_business_date
  ), offenders AS (
    SELECT store_id, count(*)::integer AS receipt_count
    FROM receipts
    WHERE (sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time
          >= TIME '21:45:00'
    GROUP BY store_id
  )
  SELECT
    (SELECT count(*)::integer FROM receipts),
    (SELECT COALESCE(sum(amount), 0)::numeric(18,2) FROM receipts),
    COALESCE((SELECT sum(receipt_count)::integer FROM offenders), 0),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'store_id', store_id,
            'receipt_count', receipt_count
          )
          ORDER BY store_id
        )
        FROM offenders
      ),
      '[]'::jsonb
    )
  INTO
    v_receipt_count,
    v_gross_sales,
    v_post_cutoff_count,
    v_offending_stores;

  IF v_post_cutoff_count > 0 THEN
    INSERT INTO public.restaurant_daily_sales_finalizations (
      business_date,
      status,
      store_count,
      receipt_count,
      gross_sales,
      post_cutoff_receipt_count,
      offending_stores,
      observed_at,
      finalized_at
    ) VALUES (
      p_business_date,
      'data_integrity_failed',
      v_store_count,
      NULL,
      NULL,
      v_post_cutoff_count,
      v_offending_stores,
      p_observed_at,
      NULL
    )
    RETURNING * INTO v_result;
  ELSE
    INSERT INTO public.restaurant_daily_sales_finalizations (
      business_date,
      status,
      store_count,
      receipt_count,
      gross_sales,
      post_cutoff_receipt_count,
      offending_stores,
      observed_at,
      finalized_at
    ) VALUES (
      p_business_date,
      'finalized',
      v_store_count,
      v_receipt_count,
      v_gross_sales,
      0,
      '[]'::jsonb,
      p_observed_at,
      p_observed_at
    )
    RETURNING * INTO v_result;
  END IF;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.restaurant_finalize_daily_sales()
RETURNS public.restaurant_daily_sales_finalizations
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.restaurant_finalize_daily_sales_at(
    (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    statement_timestamp()
  );
$$;

REVOKE ALL ON FUNCTION public.restaurant_cutoff_state_at(uuid, timestamptz)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.restaurant_assert_kitchen_mutation_allowed_at(
  uuid,
  timestamptz
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.restaurant_assert_payment_allowed_at(
  uuid,
  timestamptz
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.enforce_restaurant_daily_cutoff()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.enforce_restaurant_finalization_immutable()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restaurant_finalize_daily_sales_at(
  date,
  timestamptz
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restaurant_finalize_daily_sales()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_restaurant_cutoff_state(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restaurant_cutoff_state_at(uuid, timestamptz)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restaurant_assert_kitchen_mutation_allowed_at(
  uuid,
  timestamptz
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restaurant_assert_payment_allowed_at(
  uuid,
  timestamptz
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restaurant_finalize_daily_sales()
  TO service_role;

COMMENT ON TABLE public.restaurant_cutoff_policies IS
  'Explicit Restaurant-only activation. Stores without an enabled row, including Photo, are unaffected.';
COMMENT ON TABLE public.restaurant_daily_sales_finalizations IS
  'One immutable Restaurant sales finalization result per HCM business date.';
COMMENT ON VIEW public.v_restaurant_sales_receipts IS
  'Receipt-level Restaurant POS and delivery sale timestamps with HCM hourly buckets.';

DO $schedule$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN
      SELECT jobid
      FROM cron.job
      WHERE jobname = 'restaurant-daily-sales-finalize-2220-hcm'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;

    PERFORM cron.schedule(
      'restaurant-daily-sales-finalize-2220-hcm',
      '20 15 * * *',
      $command$SELECT public.restaurant_finalize_daily_sales()$command$
    );
  END IF;
END;
$schedule$;
