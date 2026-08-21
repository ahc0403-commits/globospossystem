-- Approval rollback contract. Run only against an explicitly named disposable
-- codex_direct_* database containing the current direct-delivery migration.
\set ON_ERROR_STOP on

BEGIN;

\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_failure_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

CREATE OR REPLACE FUNCTION direct_delivery_test.failure_snapshot(
  p_request_id uuid
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH fixture AS (
    SELECT constant.store_id, constant.ingredient_id
    FROM direct_delivery_test.constants constant
    LIMIT 1
  ), request_context AS (
    SELECT request_row.reference_code
    FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
  )
  SELECT jsonb_build_object(
    'request_state', (
      SELECT request_row.state
      FROM public.direct_order_requests request_row
      WHERE request_row.id = p_request_id
    ),
    'locked_quotes', (
      SELECT count(*) FROM public.direct_order_quotes quote
      WHERE quote.request_id = p_request_id AND quote.status = 'locked'
    ),
    'proof_messages', (
      SELECT count(*) FROM public.direct_order_messages message
      WHERE message.request_id = p_request_id
        AND message.message_type = 'payment_proof'
    ),
    'approval_messages', (
      SELECT count(*) FROM public.direct_order_messages message
      WHERE message.request_id = p_request_id
        AND message.body = 'DIRECT_ORDER_PAYMENT_APPROVED'
    ),
    'request_financials', (
      SELECT count(*) FROM public.direct_order_financials financial
      WHERE financial.request_id = p_request_id
    ),
    'store_financials', (
      SELECT count(*) FROM public.direct_order_financials financial, fixture
      WHERE financial.restaurant_id = fixture.store_id
    ),
    'orders', (
      SELECT count(*) FROM public.orders order_row, fixture
      WHERE order_row.restaurant_id = fixture.store_id
    ),
    'order_items', (
      SELECT count(*) FROM public.order_items item, fixture
      WHERE item.restaurant_id = fixture.store_id
    ),
    'payments', (
      SELECT count(*) FROM public.payments payment, fixture
      WHERE payment.restaurant_id = fixture.store_id
    ),
    'tickets', (
      SELECT count(*)
      FROM public.direct_delivery_fulfillment_tickets ticket, fixture
      WHERE ticket.restaurant_id = fixture.store_id
    ),
    'ticket_items', (
      SELECT count(*)
      FROM public.direct_delivery_fulfillment_ticket_items item, fixture
      WHERE item.restaurant_id = fixture.store_id
    ),
    'approval_audits', (
      SELECT count(*) FROM public.audit_logs audit
      WHERE audit.action = 'direct_order_payment_approved'
        AND audit.entity_id = p_request_id
    ),
    'store_audits', (
      SELECT count(*) FROM public.audit_logs audit, fixture
      WHERE audit.details->>'store_id' = fixture.store_id::text
    ),
    'inventory_stock', (
      SELECT inventory.current_stock
      FROM public.inventory_items inventory, fixture
      WHERE inventory.id = fixture.ingredient_id
    ),
    'inventory_transactions', (
      SELECT count(*) FROM public.inventory_transactions transaction_row, fixture
      WHERE transaction_row.restaurant_id = fixture.store_id
    ),
    'meinvoice_jobs', (
      SELECT count(*) FROM public.meinvoice_jobs job, fixture
      WHERE job.store_id = fixture.store_id
    ),
    'reference_orders', (
      SELECT count(*)
      FROM public.orders order_row, fixture, request_context context
      WHERE order_row.restaurant_id = fixture.store_id
        AND order_row.notes = 'Direct delivery ' || context.reference_code
    )
  )
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.raise_approval_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_stage text := current_setting('direct_order.failure_stage', true);
BEGIN
  IF v_stage = TG_ARGV[0] THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_FAILURE:%', v_stage;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER direct_test_fail_after_order
AFTER INSERT ON public.orders
FOR EACH ROW
WHEN (
  NEW.sales_channel = 'delivery'
  AND NEW.order_source = 'staff'
  AND NEW.notes LIKE 'Direct delivery D%'
)
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_order_insert'
);

CREATE TRIGGER direct_test_fail_after_order_item
AFTER INSERT ON public.order_items
FOR EACH ROW
WHEN (NEW.item_type = 'menu_item')
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_order_item_insert'
);

CREATE TRIGGER direct_test_fail_after_ticket
AFTER INSERT ON public.direct_delivery_fulfillment_tickets
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_ticket_insert'
);

CREATE TRIGGER direct_test_fail_after_ticket_item
AFTER INSERT ON public.direct_delivery_fulfillment_ticket_items
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_ticket_item_insert'
);

CREATE TRIGGER direct_test_fail_before_financial
BEFORE INSERT ON public.direct_order_financials
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'before_financial_insert'
);

CREATE TRIGGER direct_test_fail_after_financial
AFTER INSERT ON public.direct_order_financials
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_financial_insert'
);

CREATE TRIGGER direct_test_fail_before_approval_audit
BEFORE INSERT ON public.audit_logs
FOR EACH ROW
WHEN (NEW.action = 'direct_order_payment_approved')
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'before_approval_audit'
);

CREATE TRIGGER direct_test_fail_after_approval_audit
AFTER INSERT ON public.audit_logs
FOR EACH ROW
WHEN (NEW.action = 'direct_order_payment_approved')
EXECUTE FUNCTION direct_delivery_test.raise_approval_failure(
  'after_approval_audit'
);

DO $contract$
DECLARE
  v_stage text;
  v_fixture jsonb;
  v_request uuid;
  v_total numeric;
  v_before jsonb;
  v_after jsonb;
  v_error text;
  v_retry jsonb;
BEGIN
  FOREACH v_stage IN ARRAY ARRAY[
    'after_order_insert',
    'after_order_item_insert',
    'after_ticket_insert',
    'after_ticket_item_insert',
    'before_financial_insert',
    'after_financial_insert',
    'before_approval_audit',
    'after_approval_audit'
  ] LOOP
    v_fixture := direct_delivery_test.create_request('payment_review');
    v_request := (v_fixture->>'request_id')::uuid;
    v_total := (v_fixture->>'final_total')::numeric;
    v_before := direct_delivery_test.failure_snapshot(v_request);
    v_error := NULL;

    PERFORM set_config('direct_order.failure_stage', v_stage, true);
    BEGIN
      PERFORM direct_delivery_test.approve(v_request, v_total);
    EXCEPTION WHEN OTHERS THEN
      v_error := SQLERRM;
    END;
    PERFORM set_config('direct_order.failure_stage', '', true);
    v_after := direct_delivery_test.failure_snapshot(v_request);

    INSERT INTO _direct_failure_results VALUES (
      'rollback at ' || v_stage,
      v_error = 'DIRECT_DELIVERY_TEST_FAILURE:' || v_stage
        AND v_after = v_before,
      format('error=%s before=%s after=%s', v_error, v_before, v_after)
    );

    v_retry := direct_delivery_test.approve(v_request, v_total);
    PERFORM direct_delivery_test.assert_single_graph(v_request);
    INSERT INTO _direct_failure_results VALUES (
      'trigger-free retry after ' || v_stage,
      COALESCE((v_retry->>'idempotent')::boolean, true) = false
        AND (v_retry->>'ticket_id') IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.direct_order_requests request_row
          WHERE request_row.id = v_request AND request_row.state = 'approved'
        )
        AND (
          SELECT count(*) FROM public.direct_order_messages message
          WHERE message.request_id = v_request
            AND message.body = 'DIRECT_ORDER_PAYMENT_APPROVED'
        ) = 1
        AND (
          SELECT count(*) FROM public.audit_logs audit
          WHERE audit.action = 'direct_order_payment_approved'
            AND audit.entity_id = v_request
        ) = 1,
      format('retry=%s', v_retry)
    );
  END LOOP;
END;
$contract$;

DO $assertions$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || COALESCE(detail, ''), E'\n')
  INTO v_failures
  FROM _direct_failure_results
  WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_APPROVAL_FAILURE_CONTRACT_FAILED:\n%',
      v_failures;
  END IF;
END;
$assertions$;

SELECT scenario, detail
FROM _direct_failure_results
ORDER BY scenario;

ROLLBACK;
