-- Store-scoped change feed for every POS surface except the retired waiter UI.
--
-- Clients subscribe to this small, non-sensitive table instead of exposing
-- every operational table through Realtime.  A DELETE on a source table is an
-- INSERT here, so store filtering remains reliable for all mutation types.

BEGIN;

CREATE TABLE IF NOT EXISTS public.pos_live_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  restaurant_id uuid,
  domain text NOT NULL,
  source_table text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('INSERT', 'UPDATE', 'DELETE')),
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pos_live_events_store_id_idx
  ON public.pos_live_events (restaurant_id, id DESC);
CREATE INDEX IF NOT EXISTS pos_live_events_occurred_at_idx
  ON public.pos_live_events (occurred_at);

ALTER TABLE public.pos_live_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pos_live_events_authenticated_read
  ON public.pos_live_events;
CREATE POLICY pos_live_events_authenticated_read
  ON public.pos_live_events
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = pos_live_events.restaurant_id
    )
    OR (
      domain = 'photo_ops'
      AND (
        public.is_photo_objet_master()
        OR restaurant_id = public.get_photo_objet_store_id()
      )
    )
  );

DROP POLICY IF EXISTS pos_live_events_public_menu_read
  ON public.pos_live_events;
CREATE POLICY pos_live_events_public_menu_read
  ON public.pos_live_events
  FOR SELECT
  TO anon
  USING (domain IN ('menu', 'tables'));

REVOKE INSERT, UPDATE, DELETE ON public.pos_live_events FROM authenticated;
GRANT SELECT ON public.pos_live_events TO authenticated;
GRANT SELECT ON public.pos_live_events TO anon;

COMMENT ON TABLE public.pos_live_events IS
  'Non-sensitive invalidation feed. Contains no business payload; clients refetch authorized rows after an event.';

CREATE OR REPLACE FUNCTION public.emit_pos_live_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_domain text := TG_ARGV[0];
  v_row jsonb;
  v_store_id uuid;
  v_brand_id uuid;
  v_rows integer := 0;
  v_emitted boolean := false;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;

  BEGIN
    v_store_id := COALESCE(
      NULLIF(v_row ->> 'restaurant_id', '')::uuid,
      NULLIF(v_row ->> 'store_id', '')::uuid
    );
  EXCEPTION WHEN invalid_text_representation THEN
    v_store_id := NULL;
  END;

  IF TG_TABLE_NAME = 'restaurants' THEN
    v_store_id := NULLIF(v_row ->> 'id', '')::uuid;
  END IF;

  IF v_store_id IS NOT NULL THEN
    INSERT INTO public.pos_live_events (
      restaurant_id, domain, source_table, event_type
    ) VALUES (v_store_id, v_domain, TG_TABLE_NAME, TG_OP);
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  -- Child rows without a store column inherit scope from their parent.
  IF TG_TABLE_NAME = 'delivery_settlement_items' THEN
    SELECT ds.restaurant_id INTO v_store_id
    FROM public.delivery_settlements ds
    WHERE ds.id = NULLIF(v_row ->> 'settlement_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'inventory_purchase_order_lines' THEN
    SELECT po.restaurant_id INTO v_store_id
    FROM public.inventory_purchase_orders po
    WHERE po.id = NULLIF(v_row ->> 'purchase_order_id', '')::uuid;
  ELSIF TG_TABLE_NAME IN (
    'inventory_receipt_lines', 'inventory_receipt_confirmation_attempts'
  ) THEN
    SELECT ir.restaurant_id INTO v_store_id
    FROM public.inventory_receipts ir
    WHERE ir.id = NULLIF(v_row ->> 'receipt_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'inventory_recommendation_lines' THEN
    SELECT rr.restaurant_id INTO v_store_id
    FROM public.inventory_recommendation_runs rr
    WHERE rr.id = NULLIF(v_row ->> 'run_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'inventory_stock_audit_lines' THEN
    SELECT sa.restaurant_id INTO v_store_id
    FROM public.inventory_stock_audit_sessions sa
    WHERE sa.id = NULLIF(v_row ->> 'session_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'inventory_supplier_items' THEN
    SELECT ip.restaurant_id INTO v_store_id
    FROM public.inventory_products ip
    WHERE ip.id = NULLIF(v_row ->> 'product_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'meinvoice_job_events' THEN
    SELECT mj.store_id INTO v_store_id
    FROM public.meinvoice_jobs mj
    WHERE mj.id = NULLIF(v_row ->> 'job_id', '')::uuid;
  ELSIF TG_TABLE_NAME = 'qc_check_photos' THEN
    SELECT qc.restaurant_id INTO v_store_id
    FROM public.qc_checks qc
    WHERE qc.id = NULLIF(v_row ->> 'check_id', '')::uuid;
  END IF;

  IF v_store_id IS NOT NULL THEN
    INSERT INTO public.pos_live_events (
      restaurant_id, domain, source_table, event_type
    ) VALUES (v_store_id, v_domain, TG_TABLE_NAME, TG_OP);
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  -- Brand/legal-entity/global configuration changes affect multiple stores.
  BEGIN
    v_brand_id := NULLIF(v_row ->> 'brand_id', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_brand_id := NULL;
  END;

  IF TG_TABLE_NAME = 'brands' THEN
    v_brand_id := NULLIF(v_row ->> 'id', '')::uuid;
  END IF;

  IF v_brand_id IS NOT NULL THEN
    INSERT INTO public.pos_live_events (
      restaurant_id, domain, source_table, event_type
    )
    SELECT r.id, v_domain, TG_TABLE_NAME, TG_OP
    FROM public.restaurants r
    WHERE r.brand_id = v_brand_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_emitted := v_rows > 0;
  END IF;

  -- Unknown/global scope is deliberately fanned out. This favors correctness
  -- for rare hierarchy/config changes while clients debounce burst events.
  IF NOT v_emitted THEN
    INSERT INTO public.pos_live_events (
      restaurant_id, domain, source_table, event_type
    )
    SELECT r.id, v_domain, TG_TABLE_NAME, TG_OP
    FROM public.restaurants r
    WHERE r.is_active = true;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  v_item record;
BEGIN
  FOR v_item IN
    SELECT * FROM (VALUES
      ('restaurants', 'settings'),
      ('brands', 'settings'),
      ('users', 'staff'),
      ('user_store_access', 'staff'),
      ('user_brand_access', 'staff'),
      ('user_privacy_consents', 'staff'),
      ('restaurant_settings', 'settings'),
      ('restaurant_cutoff_policies', 'settings'),
      ('tables', 'tables'),
      ('table_qr_tokens', 'tables'),
      ('menu_categories', 'menu'),
      ('menu_items', 'menu'),
      ('menu_recipes', 'menu'),
      ('orders', 'orders'),
      ('order_items', 'orders'),
      ('order_discounts', 'orders'),
      ('qr_order_batches', 'orders'),
      ('pos_client_mutation_attempts', 'orders'),
      ('payments', 'payments'),
      ('payment_adjustments', 'payments'),
      ('attendance_logs', 'attendance'),
      ('staff_wage_configs', 'staff'),
      ('inventory_items', 'inventory'),
      ('inventory_transactions', 'inventory'),
      ('inventory_physical_counts', 'inventory'),
      ('inventory_suppliers', 'inventory'),
      ('inventory_products', 'inventory'),
      ('inventory_supplier_items', 'inventory'),
      ('inventory_purchase_orders', 'inventory'),
      ('inventory_purchase_order_lines', 'inventory'),
      ('inventory_receipts', 'inventory'),
      ('inventory_receipt_lines', 'inventory'),
      ('inventory_receipt_confirmation_attempts', 'inventory'),
      ('inventory_daily_consumption', 'inventory'),
      ('inventory_recommendation_runs', 'inventory'),
      ('inventory_recommendation_lines', 'inventory'),
      ('inventory_stock_audit_sessions', 'inventory'),
      ('inventory_stock_audit_lines', 'inventory'),
      ('qc_templates', 'qc'),
      ('qc_checks', 'qc'),
      ('qc_check_photos', 'qc'),
      ('qc_followups', 'qc'),
      ('office_qc_followups', 'qc'),
      ('external_sales', 'reports'),
      ('daily_closings', 'reports'),
      ('restaurant_daily_sales_finalizations', 'reports'),
      ('delivery_settlements', 'delivery'),
      ('delivery_settlement_items', 'delivery'),
      ('deliberry_operational_orders', 'delivery'),
      ('deliberry_operational_order_events', 'delivery'),
      ('printer_destinations', 'print'),
      ('print_jobs', 'print'),
      ('meinvoice_jobs', 'einvoice'),
      ('meinvoice_job_events', 'einvoice'),
      ('meinvoice_tax_entity_config', 'einvoice'),
      ('einvoice_jobs', 'einvoice'),
      ('einvoice_events', 'einvoice'),
      ('einvoice_shop', 'einvoice'),
      ('tax_entity', 'settings'),
      ('tax_entity_brands', 'settings'),
      ('store_tax_entity_history', 'settings'),
      ('system_config', 'settings'),
      ('audit_logs', 'audit'),
      ('photo_objet_stores', 'photo_ops'),
      ('photo_objet_staff', 'photo_ops'),
      ('photo_objet_sales', 'photo_ops'),
      ('photo_objet_sales_raw', 'photo_ops'),
      ('photo_objet_sales_pull_runs', 'photo_ops'),
      ('photo_objet_inventory', 'photo_ops'),
      ('photo_objet_attendance', 'photo_ops'),
      ('photo_objet_monitoring_policies', 'photo_ops'),
      ('photo_objet_expected_slots', 'photo_ops')
    ) AS configured(table_name, domain)
  LOOP
    IF to_regclass(format('public.%I', v_item.table_name)) IS NULL THEN
      CONTINUE;
    END IF;

    EXECUTE format(
      'DROP TRIGGER IF EXISTS pos_live_event_trigger ON public.%I',
      v_item.table_name
    );
    EXECUTE format(
      'CREATE TRIGGER pos_live_event_trigger AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.emit_pos_live_event(%L)',
      v_item.table_name,
      v_item.domain
    );
  END LOOP;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'pos_live_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pos_live_events;
  END IF;
END
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'pos-live-events-retention';

    PERFORM cron.schedule(
      'pos-live-events-retention',
      '17 18 * * *',
      $job$DELETE FROM public.pos_live_events WHERE occurred_at < now() - interval '3 days'$job$
    );
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron unavailable; skipped pos_live_events retention job.';
END
$$;

COMMIT;
