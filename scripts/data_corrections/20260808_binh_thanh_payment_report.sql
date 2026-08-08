\set ON_ERROR_STOP on

-- Manual, one-time production correction. This file is intentionally outside
-- supabase/migrations so application deployment cannot apply it automatically.
-- Execute only through scripts/run_pos_production_sql.sh after reviewing the
-- read-only ledger snapshot for BunsikClub Binh Thanh on 2026-08-08 (HCM).

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $$
declare
  matched_payments integer;
  item_count integer;
  item_ex_tax numeric;
  item_vat numeric;
  item_paid numeric;
  einvoice_count integer;
begin
  select count(*)
    into matched_payments
  from public.payments
  where restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'
    and (
      (id = '2b0a132b-7707-44ac-9650-fc20b0bba6a7' and order_id = 'd5c9b157-464a-49a7-9fb8-e68093d96dab' and amount = 55566 and method = 'CASH')
      or (id = '6fec9926-e84d-433d-b464-1359c755eda6' and order_id = 'd5c9b157-464a-49a7-9fb8-e68093d96dab' and amount = 55566 and method = 'OTHER')
      or (id = '03dec45e-d74b-4f3a-89cf-a8459b33ba36' and order_id = '93188508-79fc-4ba0-8eb9-e2c71b699ff2' and amount = 50896 and method = 'CASH')
      or (id = '6e2ed749-ee0b-4a31-abe7-bc472e311d3a' and order_id = '93188508-79fc-4ba0-8eb9-e2c71b699ff2' and amount = 50896 and method = 'OTHER')
      or (id = '5155c863-f6bf-4aba-b882-dd05cebb67f1' and order_id = '578b93cb-5dac-4884-85d4-d57139d64e09' and amount = 574512 and method = 'BANKTRANSFER')
      or (id = '2decac20-9781-4623-845b-55c4cf7e6bfe' and order_id = 'fb8176cd-fb5c-46fb-b3b0-7d3e7e50b98e' and amount = 95256 and method = 'BANKTRANSFER')
      or (id = '6bd2a767-7b10-42a6-bd25-3d76218c9b8a' and order_id = 'c034d136-bc1f-4fe5-afdb-6194729d3057' and amount = 258552 and method = 'BANKTRANSFER')
      or (id = '6f4a5231-9229-4a24-ad0d-aae6755bd3cb' and order_id = '0efe1fcd-38d9-423f-9919-1389e402f7d6' and amount = 373464 and method = 'BANKTRANSFER')
      or (id = 'f4ec50f8-de0f-4fcb-a66b-b3264b752a11' and order_id = 'd0dcd472-0eaa-41b1-857c-b824f865a020' and amount = 59724 and method = 'BANKTRANSFER')
      or (id = '86d1f2e7-8c46-4c24-bbf4-71f8e56fcfd3' and order_id = 'ecfeedbb-6aa6-428b-a2ef-71c01b6c2cdd' and amount = 586292 and method = 'BANKTRANSFER')
      or (id = 'b710a111-ae84-4af2-963a-0a0a33f571f1' and order_id = 'b7166161-9bc2-471c-b202-85c276c27bc3' and amount = 101304 and amount_portion = 101304 and method = 'OTHER')
    );

  if matched_payments <> 11 then
    raise exception 'Payment correction precondition failed: expected 11 exact payment rows, found %', matched_payments;
  end if;

  select count(*), sum(total_amount_ex_tax), sum(vat_amount), sum(paying_amount_inc_tax)
    into item_count, item_ex_tax, item_vat, item_paid
  from public.order_items
  where order_id = 'fb8176cd-fb5c-46fb-b3b0-7d3e7e50b98e';

  if item_count <> 3 or item_ex_tax <> 88200 or item_vat <> 7056 or item_paid <> 95256 then
    raise exception '88,200 order precondition failed: count %, ex-tax %, VAT %, paid %', item_count, item_ex_tax, item_vat, item_paid;
  end if;

  select count(*)
    into einvoice_count
  from public.einvoice_jobs
  where order_id = 'fb8176cd-fb5c-46fb-b3b0-7d3e7e50b98e';

  if einvoice_count <> 0 then
    raise exception '88,200 order already has % e-invoice job(s); manual tax review required', einvoice_count;
  end if;
end
$$;

update public.payments
set method = 'BANKTRANSFER',
    amount = case
      when id in ('2b0a132b-7707-44ac-9650-fc20b0bba6a7', '6fec9926-e84d-433d-b464-1359c755eda6') then 55500
      else amount
    end,
    proof_required = true,
    notes = concat_ws(E'\n', nullif(notes, ''), '[2026-08-08 correction] Bank transfer confirmed from settlement ledger.')
where id in (
  '2b0a132b-7707-44ac-9650-fc20b0bba6a7',
  '6fec9926-e84d-433d-b464-1359c755eda6',
  '03dec45e-d74b-4f3a-89cf-a8459b33ba36',
  '6e2ed749-ee0b-4a31-abe7-bc472e311d3a'
);

update public.payments
set method = 'BANKTRANSFER',
    amount = 103284,
    proof_required = true,
    notes = concat_ws(E'\n', nullif(notes, ''), '[2026-08-08 correction] Bank transfer received 103,284 VND; amount_portion preserves the 101,304 VND order sale amount.')
where id = 'b710a111-ae84-4af2-963a-0a0a33f571f1';

update public.payments
set method = 'CASH',
    proof_required = false,
    notes = concat_ws(E'\n', nullif(notes, ''), '[2026-08-08 correction] Cash confirmed; cashier method was incorrect.')
where id = '5155c863-f6bf-4aba-b882-dd05cebb67f1';

update public.order_items
set vat_rate = 0,
    vat_amount = 0,
    paying_amount_inc_tax = total_amount_ex_tax
where order_id = 'fb8176cd-fb5c-46fb-b3b0-7d3e7e50b98e';

update public.payments
set amount = 88200,
    amount_portion = 88200,
    notes = concat_ws(E'\n', nullif(notes, ''), '[2026-08-08 correction] Full order amount corrected from 95,256 VND to 88,200 VND.')
where id = '2decac20-9781-4623-845b-55c4cf7e6bfe';

update public.payments
set amount = case id
      when '6bd2a767-7b10-42a6-bd25-3d76218c9b8a'::uuid then 259000
      when '6f4a5231-9229-4a24-ad0d-aae6755bd3cb'::uuid then 373302
      when 'f4ec50f8-de0f-4fcb-a66b-b3264b752a11'::uuid then 59698
      when '86d1f2e7-8c46-4c24-bbf4-71f8e56fcfd3'::uuid then 587000
      else amount
    end,
    notes = concat_ws(E'\n', nullif(notes, ''), '[2026-08-08 correction] Received amount reconciled to bank settlement; amount_portion preserves the order sale amount.')
where id in (
  '6bd2a767-7b10-42a6-bd25-3d76218c9b8a',
  '6f4a5231-9229-4a24-ad0d-aae6755bd3cb',
  'f4ec50f8-de0f-4fcb-a66b-b3264b752a11',
  '86d1f2e7-8c46-4c24-bbf4-71f8e56fcfd3'
);

do $$
declare
  corrected_bank_received numeric;
  corrected_bank_portion numeric;
  corrected_cash_received numeric;
  corrected_cash_portion numeric;
  corrected_other_received numeric;
  corrected_received_total numeric;
  corrected_portion_total numeric;
  bank_statement_total numeric;
  bank_sales_total numeric;
begin
  select
    coalesce(sum(amount) filter (where method = 'BANKTRANSFER'), 0),
    coalesce(sum(amount_portion) filter (where method = 'BANKTRANSFER'), 0),
    coalesce(sum(amount) filter (where method = 'CASH'), 0),
    coalesce(sum(amount_portion) filter (where method = 'CASH'), 0),
    coalesce(sum(amount) filter (where method = 'OTHER'), 0),
    coalesce(sum(amount), 0),
    coalesce(sum(amount_portion), 0)
  into corrected_bank_received, corrected_bank_portion,
       corrected_cash_received, corrected_cash_portion,
       corrected_other_received, corrected_received_total,
       corrected_portion_total
  from public.payments
  where id in (
    '2b0a132b-7707-44ac-9650-fc20b0bba6a7',
    '6fec9926-e84d-433d-b464-1359c755eda6',
    '03dec45e-d74b-4f3a-89cf-a8459b33ba36',
    '6e2ed749-ee0b-4a31-abe7-bc472e311d3a',
    '5155c863-f6bf-4aba-b882-dd05cebb67f1',
    '2decac20-9781-4623-845b-55c4cf7e6bfe',
    '6bd2a767-7b10-42a6-bd25-3d76218c9b8a',
    '6f4a5231-9229-4a24-ad0d-aae6755bd3cb',
    'f4ec50f8-de0f-4fcb-a66b-b3264b752a11',
    '86d1f2e7-8c46-4c24-bbf4-71f8e56fcfd3',
    'b710a111-ae84-4af2-963a-0a0a33f571f1'
  );

  if corrected_bank_received <> 1683276
     or corrected_bank_portion <> 1680460
     or corrected_cash_received <> 574512
     or corrected_cash_portion <> 574512
     or corrected_other_received <> 0
     or corrected_received_total <> 2257788
     or corrected_portion_total <> 2254972 then
    raise exception 'Payment correction verification failed: bank received %, bank sales %, cash received %, cash sales %, other %, received total %, sales total %', corrected_bank_received, corrected_bank_portion, corrected_cash_received, corrected_cash_portion, corrected_other_received, corrected_received_total, corrected_portion_total;
  end if;

  select sum(amount), sum(amount_portion)
    into bank_statement_total, bank_sales_total
  from public.payments
  where method = 'BANKTRANSFER'
    and id in (
      '2b0a132b-7707-44ac-9650-fc20b0bba6a7',
      '6fec9926-e84d-433d-b464-1359c755eda6',
      '03dec45e-d74b-4f3a-89cf-a8459b33ba36',
      '6e2ed749-ee0b-4a31-abe7-bc472e311d3a',
      '86d1f2e7-8c46-4c24-bbf4-71f8e56fcfd3',
      '959de931-689d-49db-ba78-a17d9c846de5',
      '6bd2a767-7b10-42a6-bd25-3d76218c9b8a',
      '0e351e65-d4c1-452c-9f9c-4b0bb9926f00',
      '017c5fa8-04c2-4022-a7bc-b5afaf3137f4',
      '2decac20-9781-4623-845b-55c4cf7e6bfe',
      '6f4a5231-9229-4a24-ad0d-aae6755bd3cb',
      'f4ec50f8-de0f-4fcb-a66b-b3264b752a11',
      'b710a111-ae84-4af2-963a-0a0a33f571f1',
      'f22d004b-1d26-413b-bc52-4d787c6431c1'
    );

  if bank_statement_total <> 2821448 or bank_sales_total <> 2818632 then
    raise exception 'Bank settlement verification failed: received %, sales %', bank_statement_total, bank_sales_total;
  end if;

  if exists (
    select 1
    from public.order_items
    where order_id = 'fb8176cd-fb5c-46fb-b3b0-7d3e7e50b98e'
      and (vat_rate <> 0 or vat_amount <> 0 or paying_amount_inc_tax <> total_amount_ex_tax)
  ) then
    raise exception '88,200 order item verification failed';
  end if;
end
$$;

commit;
