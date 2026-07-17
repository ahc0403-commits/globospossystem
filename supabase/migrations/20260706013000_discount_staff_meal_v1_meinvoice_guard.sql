BEGIN;

-- Staff meals and other non-revenue completions must never enqueue MISA
-- first-issuance jobs. Restaurant revenue invoices remain handled by the
-- existing completed-order trigger, not by process_payment.
CREATE OR REPLACE FUNCTION public.enqueue_meinvoice_cash_register_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_tax_entity_id uuid;
  v_tax_code text;
  v_config_status text;
  v_payment_methods text[];
  v_payment_method_snapshot text;
  v_payment_summary jsonb := '[]'::jsonb;
  v_line_items_snapshot jsonb := '[]'::jsonb;
  v_status text := 'pending_manual_config';
BEGIN
  IF TG_OP <> 'UPDATE'
     OR NEW.status <> 'completed'
     OR COALESCE(OLD.status, '') = 'completed' THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.order_purpose, 'customer') = 'staff_meal' THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = NEW.id
      AND p.is_revenue = true
  ) THEN
    RETURN NEW;
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = NEW.restaurant_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(m.integration_status, 'needs_vendor_activation')
  INTO v_config_status
  FROM public.meinvoice_tax_entity_config m
  WHERE m.tax_entity_id = v_tax_entity_id;

  v_status := CASE
    WHEN COALESCE(v_config_status, 'needs_vendor_activation') = 'active'
     AND COALESCE((
       SELECT value = 'true'
       FROM public.system_config
       WHERE key = 'meinvoice_dispatch_enabled'
     ), false)
      THEN 'pending'
    ELSE 'pending_manual_config'
  END;

  SELECT COALESCE(array_agg(DISTINCT p.method ORDER BY p.method), ARRAY[]::text[])
  INTO v_payment_methods
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  v_payment_method_snapshot :=
    public.meinvoice_payment_method_label(v_tax_entity_id, v_payment_methods);

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'payment_id', p.id,
        'method', p.method,
        'amount', p.amount,
        'amount_portion', p.amount_portion,
        'created_at', p.created_at
      )
      ORDER BY p.created_at
    ),
    '[]'::jsonb
  )
  INTO v_payment_summary
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'order_item_id', oi.id,
        'item_type', oi.item_type,
        'display_name', COALESCE(NULLIF(oi.display_name, ''), oi.label, 'Item'),
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'vat_rate', oi.vat_rate,
        'vat_amount', oi.vat_amount,
        'total_amount_ex_tax', oi.total_amount_ex_tax,
        'paying_amount_inc_tax', oi.paying_amount_inc_tax
      )
      ORDER BY oi.created_at, oi.id
    ),
    '[]'::jsonb
  )
  INTO v_line_items_snapshot
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id
    AND oi.status <> 'cancelled';

  INSERT INTO public.meinvoice_jobs (
    order_id,
    store_id,
    tax_entity_id,
    buyer_kind,
    buyer_snapshot,
    payment_method_snapshot,
    payment_summary,
    line_items_snapshot,
    status
  )
  VALUES (
    NEW.id,
    NEW.restaurant_id,
    v_tax_entity_id,
    'anonymous',
    jsonb_build_object(
      'customer_name',
      'Người mua không lấy hóa đơn'
    ),
    v_payment_method_snapshot,
    v_payment_summary,
    v_line_items_snapshot,
    v_status
  )
  ON CONFLICT (order_id) DO NOTHING;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'meInvoice enqueue skipped for order %, error: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enqueue_meinvoice_cash_register_job() IS
  'Creates the restaurant MISA meInvoice first-issuance queue row after revenue order completion. Staff meals and non-revenue completions are skipped, and errors never block payment completion.';

COMMIT;
