-- Restore discounted single and combined checkout under the production
-- safe-update policy by explicitly scoping the temporary allocation update.
-- production-gate: self-verifying

DO $migration$
DECLARE
  v_rpc regprocedure := to_regprocedure(
    'public.process_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_old_fragment constant text := $old$
      UPDATE payment_discount_lines
      SET base_discount_cents = FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)::bigint,
          discount_fraction = ((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
            - FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric);$old$;
  v_new_fragment constant text := $new$
      UPDATE payment_discount_lines
      SET base_discount_cents = FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)::bigint,
          discount_fraction = ((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
            - FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
      WHERE line_inc_cents > 0;$new$;
  v_occurrences integer;
BEGIN
  IF v_rpc IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_DISCOUNT_SAFE_UPDATE_FAILED: process_payment missing';
  END IF;

  SELECT pg_get_functiondef(v_rpc::oid)
  INTO v_definition;

  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_fragment, ''))
  ) / length(v_old_fragment);

  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PAYMENT_DISCOUNT_SAFE_UPDATE_FAILED: expected one unscoped allocation update, found %',
      v_occurrences;
  END IF;

  EXECUTE replace(v_definition, v_old_fragment, v_new_fragment);

  SELECT pg_get_functiondef(v_rpc::oid)
  INTO v_definition;

  IF position(v_new_fragment IN v_definition) = 0
     OR position(v_old_fragment IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'PAYMENT_DISCOUNT_SAFE_UPDATE_FAILED: scoped allocation update not installed';
  END IF;
END;
$migration$;

