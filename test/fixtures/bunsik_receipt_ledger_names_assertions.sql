\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);
DO $$
DECLARE r jsonb; item jsonb;
BEGIN
  r:=get_receipt_ledger('2026-08-08','8bc9eef5-dcd5-46b1-b931-23f77132322c');
  item:=r #> '{receipts,0,items,0}';
  IF item->>'name' IS DISTINCT FROM '코카콜라 제로'
    OR item->>'name_ko' IS DISTINCT FROM '코카콜라 제로'
    OR item->>'name_vi' IS DISTINCT FROM 'Coca-Cola Zero'
    OR item->>'name_en' IS DISTINCT FROM 'Coca-Cola Zero'
    OR (r #>> '{summary,net_amount}')::numeric<>19440 THEN
    RAISE EXCEPTION 'LEDGER_COKE_NAME_OR_AMOUNT_INVALID: %',r; END IF;

  r:=get_receipt_ledger('2026-09-28','8bc9eef5-dcd5-46b1-b931-23f77132322c');
  item:=r #> '{receipts,0,items,0}';
  IF item->>'name' IS DISTINCT FROM '[TAKEAWAY] 환타 오렌지'
    OR item->>'name_ko' IS DISTINCT FROM '[TAKEAWAY] 환타 오렌지'
    OR item->>'name_vi' IS DISTINCT FROM '[TAKEAWAY] Fanta Cam'
    OR item->>'name_en' IS DISTINCT FROM '[TAKEAWAY] Fanta Orange'
    OR (r #>> '{summary,net_amount}')::numeric<>19440 THEN
    RAISE EXCEPTION 'LEDGER_STING_NAME_OR_AMOUNT_INVALID: %',r; END IF;

  r:=get_receipt_ledger('2026-08-07','8bc9eef5-dcd5-46b1-b931-23f77132322c');
  IF r #>> '{receipts,0,items,0,name}' IS DISTINCT FROM '콜라' THEN
    RAISE EXCEPTION 'LEDGER_DATE_BEFORE_CHANGED'; END IF;
  r:=get_receipt_ledger('2026-09-29','8bc9eef5-dcd5-46b1-b931-23f77132322c');
  IF r #>> '{receipts,0,items,0,name}' IS DISTINCT FROM '콜라' THEN
    RAISE EXCEPTION 'LEDGER_DATE_AFTER_CHANGED'; END IF;
  r:=get_receipt_ledger('2026-08-08','3a268807-771f-4fd4-84fe-e1b0b00de40a');
  IF r #>> '{receipts,0,items,0,name}' IS DISTINCT FROM '콜라' THEN
    RAISE EXCEPTION 'LEDGER_OTHER_STORE_CHANGED'; END IF;
  IF (SELECT count(*) FROM order_items WHERE display_name='콜라')<>4
    OR (SELECT count(*) FROM order_items WHERE display_name='스팅 딸기')<>1
    OR (SELECT sum(amount) FROM payments)<>97200 THEN
    RAISE EXCEPTION 'LEDGER_SOURCE_ROWS_CHANGED'; END IF;
END $$;
ROLLBACK;
