CREATE FUNCTION fixture_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'ASSERT: %', message; END IF; END $$;

INSERT INTO print_jobs(id,copy_type,order_id,payload) VALUES
  ('40000000-0000-0000-0000-000000000001','receipt','30000000-0000-0000-0000-000000000001',
   '{"total_amount":100000,"bank":{"account_number":"FORGED"}}');
SELECT fixture_assert((SELECT payload->'bank'->>'account_number'='80002014298'
  AND payload->'bank'->>'bin'='970426' AND payload->'bank'->>'label'='MSB'
  AND payload->'bank'->>'account_holder'='AKJ INTERNATIONAL CO., LTD'
  AND (payload->>'total_amount')::numeric=100000 AND (payload->>'subtotal_amount')::numeric=100000
  FROM print_jobs WHERE id='40000000-0000-0000-0000-000000000001'), 'server beneficiary and totals');
SELECT fixture_assert((SELECT NOT(payload ? 'bank') FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000099'), 'no rewrite of historical jobs');

UPDATE tax_entity_collection_accounts SET retired_at=now()
WHERE tax_entity_id='10000000-0000-0000-0000-000000000001';
INSERT INTO tax_entity_collection_accounts(tax_entity_id,bank_bin,bank_label,account_number,account_holder)
VALUES('10000000-0000-0000-0000-000000000001','970426','MSB','88888000001','AKJ INTERNATIONAL CO., LTD');
UPDATE print_jobs SET payload=jsonb_set(payload,'{bank}', '{"account_number":"FORGED"}')
WHERE id='40000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT payload->'bank'->>'account_number'='80002014298' FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000001'), 'existing queued beneficiary immutable');
INSERT INTO print_jobs(id,copy_type,order_id,payload) VALUES
  ('40000000-0000-0000-0000-000000000002','receipt','30000000-0000-0000-0000-000000000001','{"total_amount":100000}'),
  ('40000000-0000-0000-0000-000000000003','receipt','30000000-0000-0000-0000-000000000002','{"total_amount":100000}'),
  ('40000000-0000-0000-0000-000000000004','receipt','30000000-0000-0000-0000-000000000003','{"total_amount":100000}'),
  ('40000000-0000-0000-0000-000000000005','kitchen','30000000-0000-0000-0000-000000000001','{}');
SELECT fixture_assert((SELECT payload->'bank'->>'account_number'='88888000001' FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000002'), 'new job uses current account');
SELECT fixture_assert((SELECT payload->'bank'->>'account_number'='99999000001'
  AND payload->>'legal_name'='Other company' AND payload->>'tax_code'='FIXTURE-B' FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000003'), 'other legal entity remains isolated');
SELECT fixture_assert((SELECT payload->'bank'='null'::jsonb FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000004'), 'unconfigured store never gets AKJ bank');
SELECT fixture_assert((SELECT NOT(payload ? 'bank') FROM print_jobs
  WHERE id='40000000-0000-0000-0000-000000000005'), 'kitchen unchanged');

-- The lookup remains one query with a unique active-account join; no extra
-- per-job bank RPC or loop is introduced. Fixture sizes are deliberately small.
EXPLAIN (ANALYZE, BUFFERS) SELECT collection.account_number
FROM orders o JOIN restaurants r ON r.id=o.restaurant_id
LEFT JOIN tax_entity_collection_accounts collection ON collection.tax_entity_id=r.tax_entity_id
  AND collection.retired_at IS NULL AND collection.effective_from<=now()
WHERE o.id='30000000-0000-0000-0000-000000000001';
