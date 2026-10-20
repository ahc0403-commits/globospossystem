SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
INSERT INTO printer_destinations VALUES
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','kitchen',true),
 ('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','receipt',true),
 ('10000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','receipt',false),
 ('10000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000002','receipt',true);
INSERT INTO print_jobs(id,restaurant_id,destination_id,copy_type,created_at)
SELECT md5('kitchen-'||i)::uuid,'20000000-0000-0000-0000-000000000001',
 '10000000-0000-0000-0000-000000000001','kitchen',now()-interval '1 day'
FROM generate_series(1,1000) i;
INSERT INTO print_jobs(id,restaurant_id,destination_id,copy_type)
SELECT md5('receipt-'||i)::uuid,'20000000-0000-0000-0000-000000000001',
 '10000000-0000-0000-0000-000000000002',CASE WHEN i=1 THEN 'request_update' ELSE 'receipt' END
FROM generate_series(1,25) i;
INSERT INTO print_jobs(id,restaurant_id,destination_id,copy_type,payload,emergency_held_at,next_retry_at,attempts)
VALUES
 (md5('held')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','receipt','{}',now(),now(),0),
 (md5('future')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','receipt','{}',null,now()+interval '1 day',0),
 (md5('exhausted')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','receipt','{}',null,now(),10),
 (md5('version')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','receipt','{"receipt_payload_version":3}',null,now(),0),
 (md5('inactive')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003','receipt','{}',null,now(),0),
 (md5('cross-destination')::uuid,'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','receipt','{}',null,now(),0);
DO $$
DECLARE claimed int;
BEGIN
 SELECT count(*) INTO claimed FROM claim_print_station_receipt_jobs('20000000-0000-0000-0000-000000000001',0);
 IF claimed<>0 OR EXISTS(SELECT 1 FROM print_jobs WHERE attempts>0 AND id<>md5('exhausted')::uuid) THEN
  RAISE EXCEPTION 'zero-limit preflight mutated jobs'; END IF;
 BEGIN
  PERFORM claim_print_station_receipt_jobs('20000000-0000-0000-0000-000000000002',0);
  RAISE EXCEPTION 'cross-store access allowed';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'PRINT_CLAIM_FORBIDDEN' THEN RAISE; END IF;
 END;
 SELECT count(*) INTO claimed FROM claim_print_station_receipt_jobs('20000000-0000-0000-0000-000000000001',10);
 IF claimed<>10 THEN RAISE EXCEPTION 'receipt queue starved behind kitchen jobs: %',claimed; END IF;
 SELECT count(*) INTO claimed FROM claim_print_station_receipt_jobs('20000000-0000-0000-0000-000000000001',50);
 IF claimed<>15 THEN RAISE EXCEPTION 'invalid destinations/held/version jobs claimed: %',claimed; END IF;
 IF EXISTS(SELECT 1 FROM print_jobs WHERE copy_type='kitchen' AND (status<>'pending' OR attempts<>0)) THEN
  RAISE EXCEPTION 'operational jobs mutated'; END IF;
 IF NOT EXISTS(SELECT 1 FROM print_jobs WHERE copy_type='request_update' AND status='printing') THEN
  RAISE EXCEPTION 'cashier request memo not printed'; END IF;
 IF (SELECT count(*) FROM claim_print_station_receipt_jobs('20000000-0000-0000-0000-000000000001',50))<>0 THEN
  RAISE EXCEPTION 'duplicate claims'; END IF;
END $$;
-- Print mode keeps the existing operational queue available.
DO $$ BEGIN
 IF (SELECT count(*) FROM claim_print_jobs_v3('20000000-0000-0000-0000-000000000001',10))<>10 THEN
  RAISE EXCEPTION 'printer output mode regressed'; END IF;
END $$;
SELECT 'PRINT_STATION_RECEIPT_ONLY_SQL_PASS kitchen_jobs=1000 receipts=25 batch_limit=10';
