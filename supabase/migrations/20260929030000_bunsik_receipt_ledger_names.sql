-- Correct only the names returned by the receipt-ledger RPC for the confirmed
-- BunsikClub Binh Thanh business dates. Source sales and receipt rows stay intact.
CREATE FUNCTION pg_temp.replace_ledger_fragment(
  definition text, old_fragment text, new_fragment text, expected_count integer
) RETURNS text LANGUAGE plpgsql AS $helper$
DECLARE occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,old_fragment,'')))
    / length(old_fragment);
  IF occurrences <> expected_count THEN
    RAISE EXCEPTION 'LEDGER_NAME_ANCHOR_CHANGED: expected %, found %',
      expected_count,occurrences;
  END IF;
  RETURN replace(definition,old_fragment,new_fragment);
END $helper$;

DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'::regprocedure
  ) INTO definition;
  definition := pg_temp.replace_ledger_fragment(
    definition,
    $old$    WHERE item.status <> 'cancelled'$old$,
    $new$    LEFT JOIN (VALUES
      ('53249604-fd2e-40f5-a776-3e1bc5f32153'::uuid,
       '코카콜라 제로'::text,'Coca-Cola Zero'::text,'Coca-Cola Zero'::text),
      ('4eda734f-4ac9-4f05-9eeb-0a4e4b122988'::uuid,
       '환타 오렌지'::text,'Fanta Cam'::text,'Fanta Orange'::text)
    ) AS correction(menu_id,name_ko,name_vi,name_en)
      ON correction.menu_id = COALESCE(item.menu_item_id_snapshot,item.menu_item_id)
      AND order_key.store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND v_business_date BETWEEN DATE '2026-08-08' AND DATE '2026-09-28'
    WHERE item.status <> 'cancelled'$new$,1);

  definition := pg_temp.replace_ledger_fragment(
    definition,
    $old$NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'$old$,
    $new$correction.name_ko, NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'$new$,2);
  definition := pg_temp.replace_ledger_fragment(
    definition,'menu_item.name_ko',
    'COALESCE(correction.name_ko, menu_item.name_ko)',2);
  definition := pg_temp.replace_ledger_fragment(
    definition,'menu_item.name_vi',
    'COALESCE(correction.name_vi, menu_item.name_vi)',2);
  definition := pg_temp.replace_ledger_fragment(
    definition,'menu_item.name_en',
    'COALESCE(correction.name_en, menu_item.name_en)',2);

  EXECUTE definition;
END $apply$;
