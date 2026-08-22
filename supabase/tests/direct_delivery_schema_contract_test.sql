-- Direct Delivery schema/RLS/index contract. Read-only and rollback-safe.
-- Run after the effective migration chain has been applied:
--   psql -X -v ON_ERROR_STOP=1 --single-transaction "$DB_URL" \
--     -f supabase/tests/direct_delivery_schema_contract_test.sql

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _expected_direct_columns (
  table_name text NOT NULL,
  column_name text NOT NULL,
  data_type text NOT NULL,
  not_null boolean NOT NULL,
  has_default boolean NOT NULL,
  PRIMARY KEY (table_name, column_name)
);

INSERT INTO _expected_direct_columns VALUES
('direct_order_storefronts','restaurant_id','uuid',true,false),
('direct_order_storefronts','public_slug','text',true,false),
('direct_order_storefronts','is_enabled','boolean',true,true),
('direct_order_storefronts','is_paused','boolean',true,true),
('direct_order_storefronts','ordering_starts_at','time without time zone',true,true),
('direct_order_storefronts','ordering_cutoff_at','time without time zone',true,true),
('direct_order_storefronts','minimum_order_amount','numeric(15,2)',true,true),
('direct_order_storefronts','quote_ttl_minutes','integer',true,true),
('direct_order_storefronts','default_latitude','numeric(9,6)',false,false),
('direct_order_storefronts','default_longitude','numeric(9,6)',false,false),
('direct_order_storefronts','bank_bin','text',false,false),
('direct_order_storefronts','bank_account_number','text',false,false),
('direct_order_storefronts','bank_account_holder','text',false,false),
('direct_order_storefronts','bank_label','text',false,false),
('direct_order_storefronts','delivery_fee_vat_rate','numeric(5,2)',true,true),
('direct_order_storefronts','pii_retention_days','integer',true,true),
('direct_order_storefronts','analytics_min_cell_count','integer',true,true),
('direct_order_storefronts','accounting_approved_at','timestamp with time zone',false,false),
('direct_order_storefronts','accounting_approved_by','uuid',false,false),
('direct_order_storefronts','created_by','uuid',false,false),
('direct_order_storefronts','updated_by','uuid',false,false),
('direct_order_storefronts','created_at','timestamp with time zone',true,true),
('direct_order_storefronts','updated_at','timestamp with time zone',true,true),
('direct_order_sessions','id','uuid',true,true),
('direct_order_sessions','restaurant_id','uuid',true,false),
('direct_order_sessions','secret_hash','text',true,false),
('direct_order_sessions','locale','text',true,true),
('direct_order_sessions','expires_at','timestamp with time zone',true,true),
('direct_order_sessions','revoked_at','timestamp with time zone',false,false),
('direct_order_sessions','last_seen_at','timestamp with time zone',true,true),
('direct_order_sessions','created_at','timestamp with time zone',true,true),
('direct_order_public_access_limits','request_key','text',true,false),
('direct_order_public_access_limits','window_started_at','timestamp with time zone',true,false),
('direct_order_public_access_limits','request_count','integer',true,true),
('direct_order_public_access_limits','updated_at','timestamp with time zone',true,true),
('direct_order_requests','id','uuid',true,true),
('direct_order_requests','restaurant_id','uuid',true,false),
('direct_order_requests','session_id','uuid',true,false),
('direct_order_requests','client_request_id','uuid',true,false),
('direct_order_requests','reference_code','text',true,false),
('direct_order_requests','state','text',true,true),
('direct_order_requests','locale','text',true,true),
('direct_order_requests','customer_note','text',false,false),
('direct_order_requests','approved_at','timestamp with time zone',false,false),
('direct_order_requests','rejected_at','timestamp with time zone',false,false),
('direct_order_requests','cancelled_at','timestamp with time zone',false,false),
('direct_order_requests','pii_purged_at','timestamp with time zone',false,false),
('direct_order_requests','created_at','timestamp with time zone',true,true),
('direct_order_requests','updated_at','timestamp with time zone',true,true),
('direct_order_request_items','id','uuid',true,true),
('direct_order_request_items','request_id','uuid',true,false),
('direct_order_request_items','restaurant_id','uuid',true,false),
('direct_order_request_items','menu_item_id','uuid',true,false),
('direct_order_request_items','display_name','text',true,false),
('direct_order_request_items','name_ko','text',true,false),
('direct_order_request_items','name_vi','text',true,false),
('direct_order_request_items','name_en','text',true,false),
('direct_order_request_items','vat_category','text',true,false),
('direct_order_request_items','unit_price','numeric(15,2)',true,false),
('direct_order_request_items','quantity','integer',true,false),
('direct_order_request_items','item_note','text',false,false),
('direct_order_request_items','sort_order','integer',true,true),
('direct_order_request_items','created_at','timestamp with time zone',true,true),
('direct_order_request_addresses','request_id','uuid',true,false),
('direct_order_request_addresses','restaurant_id','uuid',true,false),
('direct_order_request_addresses','customer_name','text',true,false),
('direct_order_request_addresses','customer_phone','text',true,false),
('direct_order_request_addresses','formatted_address','text',true,false),
('direct_order_request_addresses','detail_address','text',true,false),
('direct_order_request_addresses','latitude','numeric(9,6)',true,false),
('direct_order_request_addresses','longitude','numeric(9,6)',true,false),
('direct_order_request_addresses','google_place_id','text',false,false),
('direct_order_request_addresses','district','text',false,false),
('direct_order_request_addresses','ward','text',false,false),
('direct_order_request_addresses','address_source','text',true,false),
('direct_order_request_addresses','location_verified','boolean',true,true),
('direct_order_request_addresses','created_at','timestamp with time zone',true,true),
('direct_order_request_addresses','updated_at','timestamp with time zone',true,true),
('direct_order_location_facts','request_id','uuid',true,false),
('direct_order_location_facts','restaurant_id','uuid',true,false),
('direct_order_location_facts','district','text',false,false),
('direct_order_location_facts','ward','text',false,false),
('direct_order_location_facts','coarse_latitude','numeric(6,3)',true,false),
('direct_order_location_facts','coarse_longitude','numeric(6,3)',true,false),
('direct_order_location_facts','requested_at','timestamp with time zone',true,false),
('direct_order_location_facts','created_at','timestamp with time zone',true,true),
('direct_order_messages','id','uuid',true,true),
('direct_order_messages','request_id','uuid',true,false),
('direct_order_messages','restaurant_id','uuid',true,false),
('direct_order_messages','sender_type','text',true,false),
('direct_order_messages','sender_auth_id','uuid',false,false),
('direct_order_messages','message_type','text',true,false),
('direct_order_messages','body','text',false,false),
('direct_order_messages','source_locale','text',false,false),
('direct_order_messages','body_ko','text',false,false),
('direct_order_messages','body_vi','text',false,false),
('direct_order_messages','body_en','text',false,false),
('direct_order_messages','translation_status','text',true,true),
('direct_order_messages','translation_provider','text',false,false),
('direct_order_messages','attachment_storage_path','text',false,false),
('direct_order_messages','metadata','jsonb',true,true),
('direct_order_messages','created_at','timestamp with time zone',true,true),
('direct_order_quotes','id','uuid',true,true),
('direct_order_quotes','request_id','uuid',true,false),
('direct_order_quotes','restaurant_id','uuid',true,false),
('direct_order_quotes','version','integer',true,false),
('direct_order_quotes','menu_pretax','numeric(15,2)',true,false),
('direct_order_quotes','menu_vat','numeric(15,2)',true,false),
('direct_order_quotes','menu_total','numeric(15,2)',true,false),
('direct_order_quotes','service_charge_pretax','numeric(15,2)',true,false),
('direct_order_quotes','service_charge_vat','numeric(15,2)',true,false),
('direct_order_quotes','service_charge_total','numeric(15,2)',true,false),
('direct_order_quotes','delivery_fee_pretax','numeric(15,2)',true,false),
('direct_order_quotes','delivery_fee_vat','numeric(15,2)',true,false),
('direct_order_quotes','delivery_fee_total','numeric(15,2)',true,false),
('direct_order_quotes','final_total','numeric(15,2)',true,false),
('direct_order_quotes','delivery_fee_vat_rate','numeric(5,2)',true,false),
('direct_order_quotes','status','text',true,true),
('direct_order_quotes','cashier_note','text',false,false),
('direct_order_quotes','created_by','uuid',true,false),
('direct_order_quotes','expires_at','timestamp with time zone',true,false),
('direct_order_quotes','locked_at','timestamp with time zone',false,false),
('direct_order_quotes','created_at','timestamp with time zone',true,true),
('direct_order_sepay_candidates','id','uuid',true,true),
('direct_order_sepay_candidates','request_id','uuid',true,false),
('direct_order_sepay_candidates','restaurant_id','uuid',true,false),
('direct_order_sepay_candidates','sepay_transaction_id','uuid',true,false),
('direct_order_sepay_candidates','linked_by','uuid',true,false),
('direct_order_sepay_candidates','linked_at','timestamp with time zone',true,true),
('direct_order_financials','request_id','uuid',true,false),
('direct_order_financials','restaurant_id','uuid',true,false),
('direct_order_financials','quote_id','uuid',true,false),
('direct_order_financials','order_id','uuid',true,false),
('direct_order_financials','payment_id','uuid',true,false),
('direct_order_financials','delivery_fee_item_id','uuid',true,false),
('direct_order_financials','menu_total','numeric(15,2)',true,false),
('direct_order_financials','service_charge_total','numeric(15,2)',true,false),
('direct_order_financials','delivery_fee_total','numeric(15,2)',true,false),
('direct_order_financials','final_total','numeric(15,2)',true,false),
('direct_order_financials','confirmed_bank_reference','text',false,false),
('direct_order_financials','approved_by','uuid',true,false),
('direct_order_financials','approved_at','timestamp with time zone',true,true),
('direct_delivery_fulfillment_tickets','id','uuid',true,true),
('direct_delivery_fulfillment_tickets','request_id','uuid',true,false),
('direct_delivery_fulfillment_tickets','restaurant_id','uuid',true,false),
('direct_delivery_fulfillment_tickets','status','text',true,true),
('direct_delivery_fulfillment_tickets','pickup_code','text',true,false),
('direct_delivery_fulfillment_tickets','version','integer',true,true),
('direct_delivery_fulfillment_tickets','accepted_at','timestamp with time zone',false,false),
('direct_delivery_fulfillment_tickets','ready_at','timestamp with time zone',false,false),
('direct_delivery_fulfillment_tickets','dispatched_at','timestamp with time zone',false,false),
('direct_delivery_fulfillment_tickets','completed_at','timestamp with time zone',false,false),
('direct_delivery_fulfillment_tickets','cancelled_at','timestamp with time zone',false,false),
('direct_delivery_fulfillment_tickets','updated_by','uuid',false,false),
('direct_delivery_fulfillment_tickets','created_at','timestamp with time zone',true,true),
('direct_delivery_fulfillment_tickets','updated_at','timestamp with time zone',true,true),
('direct_delivery_fulfillment_ticket_items','id','uuid',true,true),
('direct_delivery_fulfillment_ticket_items','ticket_id','uuid',true,false),
('direct_delivery_fulfillment_ticket_items','restaurant_id','uuid',true,false),
('direct_delivery_fulfillment_ticket_items','menu_item_id','uuid',true,false),
('direct_delivery_fulfillment_ticket_items','display_name_ko','text',true,false),
('direct_delivery_fulfillment_ticket_items','display_name_vi','text',true,false),
('direct_delivery_fulfillment_ticket_items','display_name_en','text',true,false),
('direct_delivery_fulfillment_ticket_items','quantity','integer',true,false),
('direct_delivery_fulfillment_ticket_items','item_note','text',false,false),
('direct_delivery_fulfillment_ticket_items','sort_order','integer',true,true),
('direct_delivery_fulfillment_ticket_items','created_at','timestamp with time zone',true,true),
('direct_order_dispatches','request_id','uuid',true,false),
('direct_order_dispatches','restaurant_id','uuid',true,false),
('direct_order_dispatches','grab_tracking_url','text',true,false),
('direct_order_dispatches','customer_delivery_fee','numeric(15,2)',true,false),
('direct_order_dispatches','actual_grab_fee','numeric(15,2)',false,false),
('direct_order_dispatches','fee_variance','numeric(15,2)',false,false),
('direct_order_dispatches','sent_by','uuid',true,false),
('direct_order_dispatches','sent_at','timestamp with time zone',true,true),
('direct_order_dispatches','updated_at','timestamp with time zone',true,true);

CREATE TEMP TABLE _direct_schema_failures (failure text NOT NULL);

-- Exact table/column/type/nullability/default-presence contract, including a
-- reverse diff so uncontracted columns fail too.
INSERT INTO _direct_schema_failures
SELECT format('column mismatch expected %s.%s %s not_null=%s default=%s',
              expected.table_name, expected.column_name, expected.data_type,
              expected.not_null, expected.has_default)
FROM _expected_direct_columns expected
LEFT JOIN pg_namespace namespace_row ON namespace_row.nspname = 'public'
LEFT JOIN pg_class class_row
  ON class_row.relnamespace = namespace_row.oid
 AND class_row.relname = expected.table_name
LEFT JOIN pg_attribute attribute_row
  ON attribute_row.attrelid = class_row.oid
 AND attribute_row.attname = expected.column_name
 AND attribute_row.attnum > 0
 AND NOT attribute_row.attisdropped
LEFT JOIN pg_attrdef default_row
  ON default_row.adrelid = class_row.oid
 AND default_row.adnum = attribute_row.attnum
WHERE attribute_row.attname IS NULL
   OR format_type(attribute_row.atttypid, attribute_row.atttypmod) <> expected.data_type
   OR attribute_row.attnotnull <> expected.not_null
   OR (default_row.oid IS NOT NULL) <> expected.has_default;

INSERT INTO _direct_schema_failures
SELECT format('uncontracted column %s.%s', class_row.relname, attribute_row.attname)
FROM pg_class class_row
JOIN pg_namespace namespace_row ON namespace_row.oid = class_row.relnamespace
JOIN pg_attribute attribute_row ON attribute_row.attrelid = class_row.oid
LEFT JOIN _expected_direct_columns expected
  ON expected.table_name = class_row.relname
 AND expected.column_name = attribute_row.attname
WHERE namespace_row.nspname = 'public'
  AND class_row.relname IN (SELECT DISTINCT table_name FROM _expected_direct_columns)
  AND attribute_row.attnum > 0
  AND NOT attribute_row.attisdropped
  AND expected.column_name IS NULL;

-- Semantic defaults that cannot be reduced to mere default presence.
WITH required_default(table_name, column_name, expression_pattern) AS (VALUES
  ('direct_order_storefronts','is_enabled','false'),
  ('direct_order_storefronts','is_paused','false'),
  ('direct_order_storefronts','ordering_starts_at','10:00'),
  ('direct_order_storefronts','ordering_cutoff_at','21:30'),
  ('direct_order_storefronts','minimum_order_amount','0'),
  ('direct_order_storefronts','quote_ttl_minutes','20'),
  ('direct_order_storefronts','pii_retention_days','90'),
  ('direct_order_storefronts','analytics_min_cell_count','3'),
  ('direct_order_sessions','locale','vi'),
  ('direct_order_sessions','expires_at','30 days'),
  ('direct_order_requests','state','awaiting_quote'),
  ('direct_order_requests','locale','vi'),
  ('direct_order_request_addresses','location_verified','false'),
  ('direct_order_messages','metadata','{}'),
  ('direct_order_messages','translation_status','not_requested'),
  ('direct_order_quotes','status','active'),
  ('direct_delivery_fulfillment_tickets','status','pending'),
  ('direct_delivery_fulfillment_tickets','version','1')
)
INSERT INTO _direct_schema_failures
SELECT format('default drift %s.%s expected pattern %s', required.table_name,
              required.column_name, required.expression_pattern)
FROM required_default required
JOIN pg_class class_row ON class_row.relname = required.table_name
JOIN pg_namespace namespace_row
  ON namespace_row.oid = class_row.relnamespace AND namespace_row.nspname = 'public'
JOIN pg_attribute attribute_row
  ON attribute_row.attrelid = class_row.oid AND attribute_row.attname = required.column_name
LEFT JOIN pg_attrdef default_row
  ON default_row.adrelid = class_row.oid AND default_row.adnum = attribute_row.attnum
WHERE default_row.oid IS NULL
   OR pg_get_expr(default_row.adbin, default_row.adrelid)
        NOT LIKE '%' || required.expression_pattern || '%';

-- All direct tables are RLS-on, policy-free, and inaccessible as tables to
-- browser roles. service_role remains the sole table-privileged boundary.
INSERT INTO _direct_schema_failures
SELECT format('RLS disabled on %s', expected.table_name)
FROM (SELECT DISTINCT table_name FROM _expected_direct_columns) expected
LEFT JOIN pg_class class_row ON class_row.relname = expected.table_name
LEFT JOIN pg_namespace namespace_row
  ON namespace_row.oid = class_row.relnamespace AND namespace_row.nspname = 'public'
WHERE class_row.oid IS NULL OR NOT class_row.relrowsecurity;

INSERT INTO _direct_schema_failures
SELECT format('client policy exists on %s.%s: %s', schemaname, tablename, policyname)
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (SELECT DISTINCT table_name FROM _expected_direct_columns);

WITH roles(role_name) AS (VALUES ('anon'), ('authenticated')),
tables AS (SELECT DISTINCT table_name FROM _expected_direct_columns),
privileges(privilege_name) AS (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'))
INSERT INTO _direct_schema_failures
SELECT format('table privilege leak role=%s table=%s privilege=%s', role_name, table_name, privilege_name)
FROM roles CROSS JOIN tables CROSS JOIN privileges
WHERE has_table_privilege(role_name, 'public.' || table_name, privilege_name);

INSERT INTO _direct_schema_failures
SELECT format('PUBLIC table privilege leak table=%s privilege=%s', table_name, privilege_type)
FROM information_schema.table_privileges
WHERE table_schema='public' AND grantee='PUBLIC'
  AND table_name IN (SELECT DISTINCT table_name FROM _expected_direct_columns);

INSERT INTO _direct_schema_failures
SELECT format('service_role missing table ALL on %s', table_name)
FROM (SELECT DISTINCT table_name FROM _expected_direct_columns) tables
WHERE NOT has_table_privilege('service_role', 'public.' || table_name,
                              'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');

-- Exact function exposure. A true anon permission would also reveal an
-- accidental PUBLIC grant because privileges are additive.
CREATE TEMP TABLE _expected_direct_function_access (
  signature text PRIMARY KEY,
  authenticated_execute boolean NOT NULL,
  service_execute boolean NOT NULL
);
INSERT INTO _expected_direct_function_access VALUES
('public.direct_order_require_actor(uuid,text[])',false,false),
('public.direct_order_consume_public_rate(text,integer,integer)',false,true),
('public.direct_order_public_storefront(text)',false,true),
('public.direct_order_public_create_session(text,text,text)',false,true),
('public.direct_order_validate_session(uuid,text)',false,true),
('public.direct_order_public_submit(uuid,text,uuid,jsonb)',false,true),
('public.direct_order_public_message(uuid,text,uuid,text)',false,true),
('public.direct_order_public_message_translated(uuid,text,uuid,text,text,text,text,text)',false,true),
('public.direct_order_public_message_translations(uuid,text,uuid,text,uuid[])',false,true),
('public.direct_order_public_cancel(uuid,text,uuid)',false,true),
('public.direct_order_public_commit_proof(uuid,text,uuid,text)',false,true),
('public.direct_order_public_status(uuid,text,uuid)',false,true),
('public.direct_order_admin_upsert_storefront(uuid,text,boolean,boolean,time without time zone,time without time zone,numeric,integer,numeric,numeric,text,text,text,text,numeric,integer,integer,boolean)',true,true),
('public.direct_order_admin_get_storefront(uuid)',true,true),
('public.direct_order_staff_list(uuid,text[],timestamp with time zone,uuid,integer)',true,true),
('public.direct_order_staff_detail(uuid,uuid)',true,true),
('public.direct_order_staff_quote(uuid,uuid,numeric,text)',true,true),
('public.direct_order_staff_message(uuid,uuid,text)',true,true),
('public.direct_order_staff_message_translated(uuid,uuid,uuid,text,text,text,text,text)',false,true),
('public.direct_order_staff_reject(uuid,uuid,text)',true,true),
('public.direct_order_staff_sepay_candidates(uuid,uuid)',true,true),
('public.direct_order_staff_link_sepay(uuid,uuid,uuid)',true,true),
('public.direct_order_approve_payment(uuid,uuid,numeric,text)',true,true),
('public.direct_delivery_ticket_list(uuid,text[],timestamp with time zone,uuid,integer)',true,true),
('public.direct_delivery_ticket_transition(uuid,uuid,integer,text)',true,true),
('public.direct_order_set_dispatch(uuid,uuid,text,numeric)',true,true),
('public.direct_order_analytics(uuid,date,date)',true,true),
('public.direct_order_cleanup_expired_pii(uuid[])',false,true),
('public.direct_order_cleanup_candidates(integer)',false,true),
('public.direct_order_orphan_proof_candidates(integer)',false,true);
INSERT INTO _expected_direct_function_access VALUES
('public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)',true,true);

INSERT INTO _direct_schema_failures
SELECT 'missing direct function ' || signature
FROM _expected_direct_function_access
WHERE to_regprocedure(signature) IS NULL;

INSERT INTO _direct_schema_failures
SELECT format('function privilege drift %s anon=%s authenticated=%s service=%s',
              signature,
              has_function_privilege('anon', signature, 'EXECUTE'),
              has_function_privilege('authenticated', signature, 'EXECUTE'),
              has_function_privilege('service_role', signature, 'EXECUTE'))
FROM _expected_direct_function_access
WHERE to_regprocedure(signature) IS NOT NULL
  AND (
    has_function_privilege('anon', signature, 'EXECUTE')
    OR has_function_privilege('authenticated', signature, 'EXECUTE')
         <> authenticated_execute
    OR has_function_privilege('service_role', signature, 'EXECUTE')
         <> service_execute
  );

INSERT INTO _direct_schema_failures
SELECT 'uncontracted direct function public.' || procedure_row.proname
       || '(' || pg_get_function_identity_arguments(procedure_row.oid) || ')'
FROM pg_proc procedure_row
JOIN pg_namespace namespace_row ON namespace_row.oid=procedure_row.pronamespace
WHERE namespace_row.nspname='public'
  AND (procedure_row.proname LIKE 'direct_order_%'
       OR procedure_row.proname LIKE 'direct_delivery_%')
  AND NOT EXISTS (
    SELECT 1 FROM _expected_direct_function_access expected
    WHERE to_regprocedure(expected.signature)=procedure_row.oid
  );

-- Constraint counts make every CHECK/PK/UNIQUE/FK addition or removal an
-- explicit contract change. Critical named definitions are asserted as well.
WITH expected(table_name, constraint_count) AS (VALUES
 ('direct_order_storefronts',16), ('direct_order_sessions',6),
 ('direct_order_public_access_limits',2), ('direct_order_requests',9),
 ('direct_order_request_items',9), ('direct_order_request_addresses',11),
 ('direct_order_location_facts',3), ('direct_order_messages',13),
 ('direct_order_quotes',20), ('direct_order_sepay_candidates',6),
 ('direct_order_financials',17), ('direct_delivery_fulfillment_tickets',8),
 ('direct_delivery_fulfillment_ticket_items',6), ('direct_order_dispatches',7)
), actual AS (
 SELECT class_row.relname AS table_name, count(*)::integer AS constraint_count
 FROM pg_constraint constraint_row
 JOIN pg_class class_row ON class_row.oid = constraint_row.conrelid
 JOIN pg_namespace namespace_row ON namespace_row.oid = class_row.relnamespace
 WHERE namespace_row.nspname = 'public'
   AND class_row.relname IN (SELECT table_name FROM expected)
 GROUP BY class_row.relname
)
INSERT INTO _direct_schema_failures
SELECT format('constraint count drift %s expected=%s actual=%s', expected.table_name,
              expected.constraint_count, COALESCE(actual.constraint_count,0))
FROM expected LEFT JOIN actual USING (table_name)
WHERE COALESCE(actual.constraint_count,0) <> expected.constraint_count;

WITH required(name) AS (VALUES
 ('direct_order_storefronts_slug_valid'),
 ('direct_order_storefronts_coordinates_valid'),
 ('direct_order_storefronts_bank_fields_valid'),
 ('direct_order_storefronts_accounting_gate'),
 ('direct_order_storefronts_window_valid'),
 ('direct_order_sessions_hash_valid'),
 ('direct_order_sessions_expiry_valid'),
 ('direct_order_requests_reference_valid'),
 ('direct_order_requests_note_valid'),
 ('direct_order_request_items_note_valid'),
 ('direct_order_address_name_valid'),
 ('direct_order_address_phone_valid'),
 ('direct_order_address_formatted_valid'),
 ('direct_order_address_detail_valid'),
 ('direct_order_address_place_id_valid'),
 ('direct_order_messages_content_valid'),
 ('direct_order_messages_body_valid'),
 ('direct_order_messages_attachment_valid'),
 ('direct_order_messages_source_locale_valid'),
 ('direct_order_messages_translation_status_valid'),
 ('direct_order_messages_translations_valid'),
 ('direct_order_quotes_expiry_valid'),
 ('direct_order_quotes_note_valid'),
 ('direct_order_financials_reference_valid'),
 ('direct_delivery_ticket_pickup_code_valid'),
 ('direct_delivery_ticket_item_note_valid'),
 ('direct_order_dispatches_url_valid')
)
INSERT INTO _direct_schema_failures
SELECT 'missing named constraint ' || required.name
FROM required
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = required.name);

-- Foreign-key target and delete action contract.
CREATE TEMP TABLE _expected_direct_fks (
  table_name text, column_name text, target_schema text, target_table text,
  delete_action "char"
);
INSERT INTO _expected_direct_fks VALUES
('direct_order_storefronts','restaurant_id','public','restaurants','c'),
('direct_order_storefronts','accounting_approved_by','auth','users','n'),
('direct_order_storefronts','created_by','auth','users','n'),
('direct_order_storefronts','updated_by','auth','users','n'),
('direct_order_sessions','restaurant_id','public','restaurants','c'),
('direct_order_requests','restaurant_id','public','restaurants','c'),
('direct_order_requests','session_id','public','direct_order_sessions','c'),
('direct_order_request_items','request_id','public','direct_order_requests','c'),
('direct_order_request_items','restaurant_id','public','restaurants','c'),
('direct_order_request_items','menu_item_id','public','menu_items','r'),
('direct_order_request_addresses','request_id','public','direct_order_requests','c'),
('direct_order_request_addresses','restaurant_id','public','restaurants','c'),
('direct_order_location_facts','request_id','public','direct_order_requests','c'),
('direct_order_location_facts','restaurant_id','public','restaurants','c'),
('direct_order_messages','request_id','public','direct_order_requests','c'),
('direct_order_messages','restaurant_id','public','restaurants','c'),
('direct_order_messages','sender_auth_id','auth','users','n'),
('direct_order_quotes','request_id','public','direct_order_requests','c'),
('direct_order_quotes','restaurant_id','public','restaurants','c'),
('direct_order_quotes','created_by','auth','users','a'),
('direct_order_sepay_candidates','request_id','public','direct_order_requests','c'),
('direct_order_sepay_candidates','restaurant_id','public','restaurants','c'),
('direct_order_sepay_candidates','sepay_transaction_id','public','sepay_transactions','r'),
('direct_order_sepay_candidates','linked_by','auth','users','a'),
('direct_order_financials','request_id','public','direct_order_requests','r'),
('direct_order_financials','restaurant_id','public','restaurants','r'),
('direct_order_financials','quote_id','public','direct_order_quotes','r'),
('direct_order_financials','order_id','public','orders','r'),
('direct_order_financials','payment_id','public','payments','r'),
('direct_order_financials','delivery_fee_item_id','public','order_items','r'),
('direct_order_financials','approved_by','auth','users','a'),
('direct_delivery_fulfillment_tickets','request_id','public','direct_order_requests','r'),
('direct_delivery_fulfillment_tickets','restaurant_id','public','restaurants','r'),
('direct_delivery_fulfillment_tickets','updated_by','auth','users','n'),
('direct_delivery_fulfillment_ticket_items','ticket_id','public','direct_delivery_fulfillment_tickets','c'),
('direct_delivery_fulfillment_ticket_items','restaurant_id','public','restaurants','r'),
('direct_delivery_fulfillment_ticket_items','menu_item_id','public','menu_items','r'),
('direct_order_dispatches','request_id','public','direct_order_requests','r'),
('direct_order_dispatches','restaurant_id','public','restaurants','r'),
('direct_order_dispatches','sent_by','auth','users','a');

WITH actual AS (
 SELECT source.relname table_name, source_col.attname column_name,
        target_namespace.nspname target_schema, target.relname target_table,
        constraint_row.confdeltype delete_action
 FROM pg_constraint constraint_row
 JOIN pg_class source ON source.oid = constraint_row.conrelid
 JOIN pg_class target ON target.oid = constraint_row.confrelid
 JOIN pg_namespace target_namespace ON target_namespace.oid = target.relnamespace
 JOIN pg_attribute source_col
   ON source_col.attrelid = source.oid AND source_col.attnum = constraint_row.conkey[1]
 WHERE constraint_row.contype = 'f' AND cardinality(constraint_row.conkey) = 1
)
INSERT INTO _direct_schema_failures
SELECT format('FK drift %s.%s -> %s.%s delete=%s', expected.table_name,
              expected.column_name, expected.target_schema,
              expected.target_table, expected.delete_action)
FROM _expected_direct_fks expected
LEFT JOIN actual USING (table_name,column_name,target_schema,target_table,delete_action)
WHERE actual.table_name IS NULL;

-- Business indexes: exact key order, uniqueness and predicate presence.
CREATE TEMP TABLE _expected_direct_indexes (
  index_name text PRIMARY KEY, key_columns text NOT NULL,
  is_unique boolean NOT NULL, has_predicate boolean NOT NULL
);
INSERT INTO _expected_direct_indexes VALUES
('direct_order_requests_one_open_per_session','session_id',true,true),
('direct_order_requests_store_state_created','restaurant_id,state,created_at,id',false,false),
('direct_order_requests_session_created','session_id,created_at',false,false),
('direct_order_request_items_store_request','restaurant_id,request_id',false,false),
('direct_order_request_items_menu','menu_item_id',false,false),
('direct_order_request_addresses_store','restaurant_id,request_id',false,false),
('direct_order_location_facts_store_time','restaurant_id,requested_at',false,false),
('direct_order_location_facts_region_time','restaurant_id,district,ward,requested_at',false,false),
('direct_order_messages_request_created','request_id,created_at,id',false,false),
('direct_order_messages_store_created','restaurant_id,created_at',false,false),
('direct_order_messages_attachment_unique','attachment_storage_path',true,true),
('direct_order_quotes_one_live','request_id',true,true),
('direct_order_quotes_store_created','restaurant_id,created_at',false,false),
('direct_order_sepay_candidates_store','restaurant_id,linked_at',false,false),
('direct_order_sepay_candidates_transaction','sepay_transaction_id',false,false),
('direct_order_financials_store_approved','restaurant_id,approved_at',false,false),
('direct_delivery_tickets_store_status_created','restaurant_id,status,created_at,id',false,false),
('direct_delivery_ticket_items_ticket','ticket_id,sort_order,id',false,false),
('direct_delivery_ticket_items_store','restaurant_id,ticket_id',false,false),
('direct_order_dispatches_store_sent','restaurant_id,sent_at',false,false);

WITH actual AS (
 SELECT index_class.relname index_name, index_row.indisunique is_unique,
        index_row.indpred IS NOT NULL has_predicate,
        string_agg(attribute_row.attname, ',' ORDER BY key_row.ordinality) key_columns
 FROM pg_index index_row
 JOIN pg_class index_class ON index_class.oid = index_row.indexrelid
 JOIN pg_class table_class ON table_class.oid = index_row.indrelid
 JOIN pg_namespace namespace_row ON namespace_row.oid = table_class.relnamespace
 CROSS JOIN LATERAL unnest(index_row.indkey) WITH ORDINALITY key_row(attnum, ordinality)
 JOIN pg_attribute attribute_row
   ON attribute_row.attrelid = table_class.oid AND attribute_row.attnum = key_row.attnum
 WHERE namespace_row.nspname = 'public'
 GROUP BY index_class.relname,index_row.indisunique,index_row.indpred
)
INSERT INTO _direct_schema_failures
SELECT format('index drift %s keys=%s unique=%s predicate=%s', expected.index_name,
              expected.key_columns, expected.is_unique, expected.has_predicate)
FROM _expected_direct_indexes expected
LEFT JOIN actual USING (index_name,key_columns,is_unique,has_predicate)
WHERE actual.index_name IS NULL;

INSERT INTO _direct_schema_failures
SELECT 'open-request partial index predicate drift'
WHERE NOT EXISTS (
 SELECT 1 FROM pg_indexes
 WHERE schemaname='public' AND indexname='direct_order_requests_one_open_per_session'
   AND indexdef LIKE '%awaiting_quote%quoted%awaiting_payment_review%'
);
INSERT INTO _direct_schema_failures
SELECT 'live-quote partial index predicate drift'
WHERE NOT EXISTS (
 SELECT 1 FROM pg_indexes
 WHERE schemaname='public' AND indexname='direct_order_quotes_one_live'
   AND indexdef LIKE '%active%locked%'
);

-- Proof bucket is private, narrowly typed and not exposed by storage policies.
INSERT INTO _direct_schema_failures
SELECT 'direct-order-proofs bucket contract drift'
WHERE NOT EXISTS (
 SELECT 1 FROM storage.buckets
 WHERE id='direct-order-proofs' AND name='direct-order-proofs'
   AND public=false AND file_size_limit=5242880
   AND allowed_mime_types @> ARRAY['image/jpeg','image/png','image/webp']
   AND cardinality(allowed_mime_types)=3
);
INSERT INTO _direct_schema_failures
SELECT 'direct-order-proofs client storage policy leak: ' || policyname
FROM pg_policies
WHERE schemaname='storage' AND tablename='objects'
  AND (qual LIKE '%direct-order-proofs%' OR with_check LIKE '%direct-order-proofs%');

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(failure, E'\n' ORDER BY failure) INTO v_failures
  FROM _direct_schema_failures;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_SCHEMA_CONTRACT_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_SCHEMA_CONTRACT_PASS' AS result,
       (SELECT count(*) FROM _expected_direct_columns) AS contracted_columns,
       (SELECT count(*) FROM _expected_direct_fks) AS contracted_fks,
       (SELECT count(*) FROM _expected_direct_indexes) AS contracted_indexes,
       (SELECT count(*) FROM _expected_direct_function_access) AS contracted_functions;

ROLLBACK;
