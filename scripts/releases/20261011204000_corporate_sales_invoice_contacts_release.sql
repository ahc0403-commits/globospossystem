-- Generated atomic release: apply only through the official POS production gate.
-- Canonical components are source definitions; production records only bundle version 20261011204000.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';
-- Read-only prerequisites; emits no customer values or credentials.
DO $preflight$
DECLARE definitions jsonb; eligible integer;
BEGIN
 SELECT jsonb_object_agg(signature,pg_get_functiondef(to_regprocedure(signature))) INTO definitions FROM (VALUES
 ('public.direct_order_public_resume_storefront(uuid,text)'),
 ('public.direct_order_admin_get_storefront(uuid)'),
 ('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'),
 ('public.enqueue_meinvoice_cash_register_job()'),
 ('public.claim_meinvoice_jobs(uuid,integer,uuid)')) required(signature);
 IF EXISTS(SELECT 1 FROM jsonb_each(definitions) d WHERE d.value='null'::jsonb) THEN RAISE EXCEPTION 'CORPORATE_RELEASE_PREREQUISITE_MISSING'; END IF;
 IF strpos(definitions->>'public.direct_order_admin_get_storefront(uuid)', '''accounting_approved'', v_row.accounting_approved_at IS NOT NULL')=0
 OR strpos(definitions->>'public.direct_order_public_resume_storefront(uuid,text)', 'RETURN v_result;')=0
 OR strpos(definitions->>'public.get_restaurant_daily_sales_exports_by_tax_entity(date)', 'public.pos_restaurant_receipt_rows(')=0
 OR strpos(definitions->>'public.enqueue_meinvoice_cash_register_job()', '''item_type'', oi.item_type,')=0
 OR strpos(definitions->>'public.enqueue_meinvoice_cash_register_job()', '  WHERE oi.order_id = NEW.id')=0
 OR strpos(definitions->>'public.claim_meinvoice_jobs(uuid,integer,uuid)', 'status=''pending'' AND dispatch_claim_id IS NULL')=0 THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ANCHOR_CHANGED'; END IF;
 IF to_regclass('public.tax_entity_collection_accounts') IS NOT NULL OR to_regclass('public.menu_invoice_profiles') IS NOT NULL
 OR to_regclass('public.meinvoice_job_snapshot_versions') IS NOT NULL
 OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND
 ((table_name='direct_order_sessions' AND column_name='collection_bank_snapshot') OR (table_name='meinvoice_jobs' AND column_name='snapshot_version')
 OR (table_name='menu_items' AND column_name IN('invoice_name_vi','invoice_unit_name')))) THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ALREADY_PARTIALLY_APPLIED'; END IF;
 SELECT count(*) INTO eligible FROM public.tax_entity WHERE id='a6bda671-4179-5a29-a798-76357b42b497'::uuid
 OR upper(regexp_replace(name,'[^A-Za-z]','','g'))='AKJINTERNATIONALCOLTD';
 IF eligible<>1 THEN RAISE EXCEPTION 'CORPORATE_RELEASE_AKJ_ENTITY_AMBIGUOUS'; END IF;
 RAISE NOTICE 'CORPORATE_RELEASE_PREFLIGHT=PASS';
END $preflight$;

-- COMPONENT 20261011200000_corporate_collection_accounts.sql SHA256 94fb2c39bdd2405e8209638c4a64537a78a5d46e6c2eb99ba4ca510b5613958b

-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
CREATE TABLE public.tax_entity_collection_accounts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
 bank_bin text NOT NULL CHECK(bank_bin ~ '^[0-9]{6}$'),
 bank_label text NOT NULL CHECK(length(btrim(bank_label)) BETWEEN 1 AND 120),
 account_number text NOT NULL CHECK(account_number ~ '^[A-Za-z0-9]{5,19}$'),
 account_holder text NOT NULL CHECK(length(btrim(account_holder)) BETWEEN 2 AND 120),
 effective_from timestamptz NOT NULL DEFAULT now(),
 retired_at timestamptz,
 created_by uuid DEFAULT auth.uid(),
 CHECK(retired_at IS NULL OR retired_at>=effective_from)
);
CREATE UNIQUE INDEX collection_account_one_active ON public.tax_entity_collection_accounts(tax_entity_id) WHERE retired_at IS NULL;
ALTER TABLE public.tax_entity_collection_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tax_entity_collection_accounts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tax_entity_collection_accounts TO authenticated;
CREATE POLICY collection_accounts_read ON public.tax_entity_collection_accounts FOR SELECT TO authenticated
 USING(public.is_super_admin() OR EXISTS(SELECT 1 FROM public.restaurants r
 JOIN public.user_accessible_stores(auth.uid()) s(store_id) ON s.store_id=r.id WHERE r.tax_entity_id=tax_entity_collection_accounts.tax_entity_id));

CREATE FUNCTION public.get_store_collection_bank(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE bank jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT(public.is_super_admin() OR EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id)) THEN RAISE EXCEPTION 'COLLECTION_BANK_FORBIDDEN'; END IF;
 SELECT jsonb_build_object('id',a.id,'tax_entity_id',a.tax_entity_id,'bin',a.bank_bin,'label',a.bank_label,
 'account_number',a.account_number,'account_holder',a.account_holder,'effective_from',a.effective_from)
 INTO bank FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id
 WHERE r.id=p_store_id AND a.retired_at IS NULL AND a.effective_from<=now();
 IF bank IS NULL THEN RAISE EXCEPTION 'COLLECTION_BANK_NOT_CONFIGURED'; END IF;
 RETURN bank;
END $$;
REVOKE ALL ON FUNCTION public.get_store_collection_bank(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_store_collection_bank(uuid) TO authenticated;

CREATE FUNCTION public.set_tax_entity_collection_bank(p_tax_entity_id uuid,p_bin text,p_label text,p_account text,p_holder text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'COLLECTION_BANK_FORBIDDEN'; END IF;
 PERFORM 1 FROM public.tax_entity WHERE id=p_tax_entity_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'COLLECTION_ENTITY_NOT_FOUND'; END IF;
 IF EXISTS(SELECT 1 FROM public.tax_entity_collection_accounts WHERE tax_entity_id=p_tax_entity_id AND retired_at IS NULL
 AND bank_bin=p_bin AND bank_label=btrim(p_label) AND account_number=p_account AND account_holder=btrim(p_holder)) THEN
 SELECT to_jsonb(a) INTO result FROM public.tax_entity_collection_accounts a WHERE tax_entity_id=p_tax_entity_id AND retired_at IS NULL; RETURN result; END IF;
 UPDATE public.tax_entity_collection_accounts SET retired_at=now() WHERE tax_entity_id=p_tax_entity_id AND retired_at IS NULL;
 INSERT INTO public.tax_entity_collection_accounts(tax_entity_id,bank_bin,bank_label,account_number,account_holder)
 VALUES(p_tax_entity_id,p_bin,btrim(p_label),p_account,btrim(p_holder)) RETURNING to_jsonb(tax_entity_collection_accounts) INTO result;
 UPDATE public.direct_order_storefronts SET bank_bin=p_bin,bank_label=btrim(p_label),bank_account_number=p_account,bank_account_holder=btrim(p_holder)
 WHERE restaurant_id IN(SELECT id FROM public.restaurants WHERE tax_entity_id=p_tax_entity_id);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.set_tax_entity_collection_bank(uuid,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_tax_entity_collection_bank(uuid,text,text,text,text) TO authenticated;

-- Snapshot open legacy sessions before changing their displayed beneficiary.
ALTER TABLE public.direct_order_sessions ADD COLUMN collection_bank_snapshot jsonb;
UPDATE public.direct_order_sessions s SET collection_bank_snapshot=jsonb_build_object('bin',sf.bank_bin,'label',sf.bank_label,'account_number',sf.bank_account_number,'account_holder',sf.bank_account_holder)
 FROM public.direct_order_storefronts sf WHERE sf.restaurant_id=s.restaurant_id;

-- Only the owner's AKJ entity; no blanket change of tenant accounts.
INSERT INTO public.tax_entity_collection_accounts(tax_entity_id,bank_bin,bank_label,account_number,account_holder)
 SELECT id,'970426','MSB','80002014298','AKJ INTERNATIONAL CO., LTD' FROM public.tax_entity
 WHERE id='a6bda671-4179-5a29-a798-76357b42b497'::uuid OR upper(regexp_replace(name,'[^A-Za-z]','','g'))='AKJINTERNATIONALCOLTD';
UPDATE public.direct_order_storefronts sf SET bank_bin=a.bank_bin,bank_label=a.bank_label,
 bank_account_number=a.account_number,bank_account_holder=a.account_holder
 FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id AND a.retired_at IS NULL
 WHERE sf.restaurant_id=r.id;
CREATE FUNCTION public.direct_order_canonical_collection_bank() RETURNS trigger LANGUAGE plpgsql
 SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE a public.tax_entity_collection_accounts;
BEGIN
 SELECT bank.* INTO a FROM public.restaurants r JOIN public.tax_entity_collection_accounts bank ON bank.tax_entity_id=r.tax_entity_id
 WHERE r.id=NEW.restaurant_id AND bank.retired_at IS NULL AND bank.effective_from<=now();
 IF FOUND THEN NEW.bank_bin:=a.bank_bin; NEW.bank_label:=a.bank_label; NEW.bank_account_number:=a.account_number;NEW.bank_account_holder:=a.account_holder; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER direct_order_canonical_collection_bank BEFORE INSERT OR UPDATE ON public.direct_order_storefronts
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_canonical_collection_bank();

-- The customer device reads this account from the published order snapshot.
CREATE FUNCTION public.customer_display_collection_bank_snapshot() RETURNS trigger LANGUAGE plpgsql
 SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE bank jsonb;
BEGIN
 IF NEW.status<>'showing' OR NEW.payload IS NULL OR NEW.payload->>'phase'='receipt' THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' AND OLD.order_id=NEW.order_id AND OLD.payload->'bank' IS NOT NULL AND OLD.payload->'bank'<>'null'::jsonb THEN bank:=OLD.payload->'bank';
 ELSE SELECT jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder)
 INTO bank FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id
 WHERE r.id=NEW.store_id AND a.retired_at IS NULL AND a.effective_from<=now(); END IF;
 NEW.payload:=NEW.payload||jsonb_build_object('bank',bank); RETURN NEW;
END $$;
CREATE TRIGGER customer_display_collection_bank_snapshot BEFORE INSERT OR UPDATE ON public.customer_payment_displays
 FOR EACH ROW EXECUTE FUNCTION public.customer_display_collection_bank_snapshot();

CREATE FUNCTION public.direct_order_session_collection_bank_snapshot() RETURNS trigger LANGUAGE plpgsql
 SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 SELECT jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder)
 INTO NEW.collection_bank_snapshot FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id
 WHERE r.id=NEW.restaurant_id AND a.retired_at IS NULL AND a.effective_from<=now();
 IF NEW.collection_bank_snapshot IS NULL THEN SELECT jsonb_build_object('bin',sf.bank_bin,'label',sf.bank_label,'account_number',sf.bank_account_number,'account_holder',sf.bank_account_holder)
 INTO NEW.collection_bank_snapshot FROM public.direct_order_storefronts sf WHERE sf.restaurant_id=NEW.restaurant_id; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER direct_order_session_collection_bank_snapshot BEFORE INSERT ON public.direct_order_sessions FOR EACH ROW EXECUTE FUNCTION public.direct_order_session_collection_bank_snapshot();
CREATE FUNCTION public.get_order_collection_bank(p_store_id uuid,p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE bank jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT(public.is_super_admin() OR EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id)) THEN RAISE EXCEPTION 'COLLECTION_BANK_FORBIDDEN'; END IF;
 SELECT payload->'bank' INTO bank FROM public.customer_payment_displays WHERE store_id=p_store_id AND order_id=p_order_id AND status='showing' AND payload->>'phase'='payment';
 IF bank IS NULL OR bank='null'::jsonb THEN bank:=public.get_store_collection_bank(p_store_id); END IF;
 RETURN bank;
END $$;
REVOKE ALL ON FUNCTION public.get_order_collection_bank(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_order_collection_bank(uuid,uuid) TO authenticated;
-- Preserve legacy sessions' original storefront bank; do not rewrite past payment records.
DO $patch$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.direct_order_public_resume_storefront(uuid,text)'::regprocedure) INTO d;
 d:=replace(d,'IF v_result IS NOT NULL THEN RETURN v_result; END IF;',
 'IF v_result IS NOT NULL THEN RETURN CASE WHEN v_session.collection_bank_snapshot IS NULL THEN v_result ELSE v_result||jsonb_build_object(''bank'',v_session.collection_bank_snapshot) END; END IF;');
 d:=replace(d,'RETURN v_result;', 'RETURN CASE WHEN v_session.collection_bank_snapshot IS NULL THEN v_result ELSE v_result||jsonb_build_object(''bank'',v_session.collection_bank_snapshot) END;');
 EXECUTE d;
END $patch$;
DO $settings$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.direct_order_admin_get_storefront(uuid)'::regprocedure) INTO d;
 IF strpos(d,'''accounting_approved'', v_row.accounting_approved_at IS NOT NULL')=0 THEN RAISE EXCEPTION 'COLLECTION_SETTINGS_ANCHOR_CHANGED'; END IF;
 d:=replace(d,E'''accounting_approved'', false\n    );', E'''accounting_approved'', false\n    ) || COALESCE((SELECT jsonb_build_object(''collection_bank_managed'',true,''bank_bin'',a.bank_bin,''bank_label'',a.bank_label,''bank_account_number'',a.account_number,''bank_account_holder'',a.account_holder) FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id WHERE r.id=p_store_id AND a.retired_at IS NULL),''{}''::jsonb);');
 EXECUTE replace(d,'''accounting_approved'', v_row.accounting_approved_at IS NOT NULL',
 '''accounting_approved'', v_row.accounting_approved_at IS NOT NULL, ''collection_bank_managed'', EXISTS(SELECT 1 FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id WHERE r.id=p_store_id AND a.retired_at IS NULL)');
END $settings$;
DO $verify$ BEGIN
 IF has_function_privilege('anon','public.get_store_collection_bank(uuid)','EXECUTE') OR has_function_privilege('anon','public.set_tax_entity_collection_bank(uuid,text,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'COLLECTION_BANK_SCOPE_DRIFT'; END IF;
END $verify$;

-- COMPONENT 20261011201000_invoice_ledger_export_contract.sql SHA256 0a13c6783eab548bd1cb49a55ea3ed27c1cb9d5dc221dc69ddd2248260dc391d

-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
-- Invoice descriptions and units only: no VAT master or monetary snapshot changes.
CREATE TABLE public.menu_invoice_profiles(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),menu_item_id uuid NOT NULL REFERENCES public.menu_items(id),
 invoice_name_vi text NOT NULL CHECK(length(btrim(invoice_name_vi)) BETWEEN 1 AND 200),
 unit_name text NOT NULL CHECK(length(btrim(unit_name)) BETWEEN 1 AND 40),
 effective_from timestamptz NOT NULL,effective_to timestamptz,
 approved_by uuid NOT NULL DEFAULT auth.uid(),approved_at timestamptz NOT NULL DEFAULT now(),
 CHECK(effective_to IS NULL OR effective_to>effective_from)
);
CREATE UNIQUE INDEX menu_invoice_profile_one_active ON public.menu_invoice_profiles(menu_item_id) WHERE effective_to IS NULL;
CREATE INDEX menu_invoice_profile_history ON public.menu_invoice_profiles(menu_item_id,effective_from DESC);
ALTER TABLE public.menu_invoice_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.menu_invoice_profiles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.menu_invoice_profiles TO authenticated;
CREATE POLICY menu_invoice_profiles_read ON public.menu_invoice_profiles FOR SELECT TO authenticated USING(public.is_super_admin()
 OR EXISTS(SELECT 1 FROM public.menu_items m JOIN public.user_accessible_stores(auth.uid()) s(store_id) ON s.store_id=m.restaurant_id WHERE m.id=menu_item_id));
ALTER TABLE public.menu_items ADD COLUMN invoice_name_vi text,ADD COLUMN invoice_unit_name text;
CREATE FUNCTION public.approve_menu_invoice_profile(p_menu_item_id uuid,p_name text,p_unit text,p_effective_from timestamptz DEFAULT now()) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE started timestamptz;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 PERFORM 1 FROM public.menu_items WHERE id=p_menu_item_id FOR UPDATE;
 IF NOT FOUND OR p_effective_from IS NULL OR p_effective_from>now() THEN RAISE EXCEPTION 'INVOICE_PROFILE_INVALID'; END IF;
 SELECT effective_from INTO started FROM public.menu_invoice_profiles WHERE menu_item_id=p_menu_item_id AND effective_to IS NULL;
 IF started IS NOT NULL AND p_effective_from<=started THEN RAISE EXCEPTION 'INVOICE_PROFILE_HISTORY_OVERLAP'; END IF;
 UPDATE public.menu_invoice_profiles SET effective_to=p_effective_from WHERE menu_item_id=p_menu_item_id AND effective_to IS NULL;
 INSERT INTO public.menu_invoice_profiles(menu_item_id,invoice_name_vi,unit_name,effective_from)
 VALUES(p_menu_item_id,btrim(p_name),btrim(p_unit),p_effective_from);
 UPDATE public.menu_items SET invoice_name_vi=btrim(p_name),invoice_unit_name=btrim(p_unit) WHERE id=p_menu_item_id;
END $$;
REVOKE ALL ON FUNCTION public.approve_menu_invoice_profile(uuid,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_menu_invoice_profile(uuid,text,text,timestamptz) TO authenticated;
CREATE FUNCTION public.misa_payment_code_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value),
 labels AS(SELECT DISTINCT CASE method WHEN 'CASH' THEN 'TM' WHEN 'BANKTRANSFER' THEN 'CK'
 WHEN 'CREDITCARD' THEN 'Thẻ quốc tế' WHEN 'ATM' THEN 'Thẻ ATM' ELSE 'Ví điện tử' END label FROM methods)
 SELECT CASE WHEN count(*)=0 OR bool_or(method NOT IN('CASH','BANKTRANSFER','CREDITCARD','ATM','OTHER','EPAY','PAY')) THEN 'UNMAPPED'
 WHEN count(*)=2 AND bool_and(method IN('CASH','BANKTRANSFER')) THEN 'TM/CK'
 ELSE (SELECT string_agg(label,'/' ORDER BY label COLLATE "C") FROM labels) END FROM methods;
$$;
CREATE OR REPLACE FUNCTION public.meinvoice_payment_method_label(p_tax_entity_id uuid,p_methods text[]) RETURNS text
 LANGUAGE sql STABLE SET search_path=public,pg_catalog AS $$ SELECT public.misa_payment_code_for_methods(p_methods); $$;
ALTER TABLE public.meinvoice_jobs ADD COLUMN snapshot_version integer NOT NULL DEFAULT 1;
ALTER TABLE public.meinvoice_jobs ALTER COLUMN snapshot_version SET DEFAULT 2;
CREATE TABLE public.meinvoice_job_snapshot_versions(
 job_id uuid NOT NULL REFERENCES public.meinvoice_jobs(id),snapshot_version integer NOT NULL,
 payment_method_snapshot text NOT NULL,line_items_snapshot jsonb NOT NULL,payment_summary jsonb NOT NULL,
 source_hash text NOT NULL,captured_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(job_id,snapshot_version)
);
ALTER TABLE public.meinvoice_job_snapshot_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meinvoice_job_snapshot_versions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.meinvoice_job_snapshot_versions TO authenticated;
CREATE POLICY invoice_versions_read ON public.meinvoice_job_snapshot_versions FOR SELECT TO authenticated USING(public.is_super_admin());
CREATE FUNCTION public.preserve_meinvoice_export_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF OLD.payment_method_snapshot IS NOT DISTINCT FROM NEW.payment_method_snapshot AND OLD.line_items_snapshot IS NOT DISTINCT FROM NEW.line_items_snapshot AND OLD.payment_summary IS NOT DISTINCT FROM NEW.payment_summary THEN RETURN NEW; END IF;
 IF OLD.status IN('sent_to_misa','sent_to_tax_authority','valid_invoice','resolved') OR OLD.misa_ref_id IS NOT NULL OR OLD.invoice_number IS NOT NULL OR OLD.dispatch_claim_id IS NOT NULL OR COALESCE(OLD.dispatch_attempts,0)>0 THEN RAISE EXCEPTION 'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE'; END IF;
 INSERT INTO public.meinvoice_job_snapshot_versions(job_id,snapshot_version,payment_method_snapshot,line_items_snapshot,payment_summary,source_hash)
 VALUES(OLD.id,OLD.snapshot_version,OLD.payment_method_snapshot,OLD.line_items_snapshot,OLD.payment_summary,
 md5(jsonb_build_object('method',OLD.payment_method_snapshot,'items',OLD.line_items_snapshot,'payments',OLD.payment_summary)::text)) ON CONFLICT DO NOTHING;
 NEW.snapshot_version:=OLD.snapshot_version+1; RETURN NEW;
END $$;
CREATE TRIGGER preserve_meinvoice_export_snapshot BEFORE UPDATE ON public.meinvoice_jobs FOR EACH ROW EXECUTE FUNCTION public.preserve_meinvoice_export_snapshot();
CREATE FUNCTION public.pos_restaurant_receipt_rows_v2(p_business_date date,p_order_ids uuid[] DEFAULT NULL)
RETURNS TABLE(tax_entity_id uuid,seller_tax_code text,seller_legal_name text,is_sample_entity boolean,receipt_id text,store_id uuid,
 store_name text,receipt_source text,source_system text,sales_channel text,sold_at timestamptz,gross_sales numeric,payment_method text,
 is_red_invoice boolean,red_invoice_status text,buyer_tax_code text,buyer_legal_name text,buyer_address text,buyer_email text,buyer_phone text,line_items jsonb,receipt_number text,payment_methods text[],snapshot_version integer,source_hash text,payment_code text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $rows$
  WITH candidates AS MATERIALIZED(
    SELECT DISTINCT payment.order_id FROM public.payments payment
    WHERE payment.is_revenue AND payment.created_at >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh') AND payment.created_at < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
      AND (p_order_ids IS NULL OR payment.order_id=ANY(p_order_ids))
  ), paid_orders AS MATERIALIZED (
    SELECT
      payment.order_id,
      payment.restaurant_id AS store_id,
      max(payment.created_at) AS sold_at,
      round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
        AS gross_sales,
      array_agg(DISTINCT payment.method ORDER BY payment.method)
        AS payment_methods
    FROM public.payments payment JOIN candidates scope ON scope.order_id=payment.order_id
    JOIN public.orders issued_order
      ON issued_order.id = payment.order_id
     AND issued_order.status = 'completed'
    JOIN public.restaurants restaurant
      ON restaurant.id = payment.restaurant_id
     AND restaurant.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
    WHERE payment.is_revenue = true
      AND restaurant.id <> '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
      AND restaurant.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
    GROUP BY payment.order_id, payment.restaurant_id
    HAVING max(payment.created_at) >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
       AND max(payment.created_at) < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ),
  latest_jobs AS MATERIALIZED (
    SELECT DISTINCT ON(candidate.order_id) candidate.order_id,candidate.tax_entity_id,candidate.payment_method_snapshot,candidate.line_items_snapshot,candidate.snapshot_version
    FROM public.meinvoice_jobs candidate JOIN paid_orders scope ON scope.order_id=candidate.order_id
    WHERE candidate.source_system='restaurant_pos' ORDER BY candidate.order_id,candidate.created_at DESC,candidate.id DESC
  ), historical_entities AS MATERIALIZED (
    SELECT DISTINCT ON(scope.order_id) scope.order_id,history.tax_entity_id
    FROM paid_orders scope JOIN public.store_tax_entity_history history ON history.store_id=scope.store_id
    AND history.effective_from<=scope.sold_at AND (history.effective_to IS NULL OR scope.sold_at<history.effective_to)
    ORDER BY scope.order_id,history.effective_from DESC,history.created_at DESC
  ), approved_profiles AS MATERIALIZED (
    SELECT DISTINCT ON(item.id) item.id,profile.id profile_id,profile.invoice_name_vi,profile.unit_name
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=item.menu_item_id
      AND profile.effective_from<=scope.sold_at AND (profile.effective_to IS NULL OR scope.sold_at<profile.effective_to)
    ORDER BY item.id,profile.effective_from DESC,profile.id DESC
  ), order_lines AS MATERIALIZED (
    SELECT item.order_id,jsonb_agg(jsonb_build_object(
      'order_item_id',CASE WHEN item.vat_rate=-1 THEN item.id::text||':'||(part->>'vat_rate') ELSE item.id::text END,
      'menu_item_id',item.menu_item_id,'invoice_profile_id',profile.profile_id,
      'display_name',COALESCE(NULLIF(item.display_name,''),NULLIF(item.label,''),'Món ăn'),
      'invoice_name_vi',profile.invoice_name_vi,'misa_unit_name',profile.unit_name,
      'item_type',item.item_type,'quantity',CASE WHEN item.vat_rate=-1 THEN 1 ELSE item.quantity END,
      'misa_unit_price',(part->>'total_amount_ex_tax')::numeric/NULLIF(CASE WHEN item.vat_rate=-1 THEN 1 ELSE item.quantity END,0), 'misa_discount_amount',0,
      'unit_price',CASE WHEN item.vat_rate=-1 THEN (part->>'total_amount_ex_tax')::numeric ELSE item.unit_price END,
      'total_amount_ex_tax',(part->>'total_amount_ex_tax')::numeric,
      'vat_rate',(part->>'vat_rate')::numeric,'vat_amount',(part->>'vat_amount')::numeric,
      'paying_amount_inc_tax',COALESCE((part->>'paying_amount_inc_tax')::numeric,(part->>'total_amount_ex_tax')::numeric+(part->>'vat_amount')::numeric)) ORDER BY item.created_at,item.id,part->>'vat_rate') line_items
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    LEFT JOIN approved_profiles profile ON profile.id=item.id
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN item.vat_rate=-1 THEN item.vat_breakdown
      ELSE jsonb_build_array(jsonb_build_object('vat_rate',item.vat_rate,'vat_amount',item.vat_amount,
        'total_amount_ex_tax',item.total_amount_ex_tax,'paying_amount_inc_tax',item.paying_amount_inc_tax)) END) part
    WHERE item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false GROUP BY item.order_id
  ), receipt_candidates AS MATERIALIZED(
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope
    JOIN public.digital_receipts d ON d.order_id=scope.order_id AND d.restaurant_id=scope.store_id
    UNION ALL
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope JOIN public.payments p ON p.order_id=scope.order_id AND p.restaurant_id=scope.store_id AND p.is_revenue
    JOIN public.digital_receipts d ON d.combined_payment_group_id=p.combined_payment_group_id AND d.order_id IS NULL AND d.restaurant_id=scope.store_id
  ), receipt_numbers AS MATERIALIZED(
    SELECT DISTINCT ON(order_id) order_id,receipt_number FROM receipt_candidates ORDER BY order_id,created_at DESC,id DESC
  ), report_rows AS (
    SELECT
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      seller.id = '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid AS is_sample_entity,
      paid.order_id::text AS receipt_id,
      paid.store_id,
      restaurant.name AS store_name,
      'pos_payment'::text AS receipt_source,
      'restaurant_pos'::text AS source_system,
      orders.sales_channel,
      paid.sold_at,
      paid.gross_sales,
      public.misa_payment_code_for_methods(paid.payment_methods) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(intake.buyer_email, '') AS buyer_email,
      COALESCE(intake.buyer_phone, '') AS buyer_phone,
      COALESCE(CASE WHEN job.snapshot_version>=2 THEN NULLIF(job.line_items_snapshot,'[]'::jsonb) END,
        order_lines.line_items,'[]'::jsonb) AS line_items,
      COALESCE(receipt_number.receipt_number,'POS-'||upper(substr(replace(paid.order_id::text,'-',''),1,10))) AS receipt_number,
      paid.payment_methods,COALESCE(job.snapshot_version,1),
      md5(jsonb_build_object('order_id',paid.order_id,'gross',paid.gross_sales,'methods',paid.payment_methods,
        'items',COALESCE(CASE WHEN job.snapshot_version>=2 THEN NULLIF(job.line_items_snapshot,'[]'::jsonb) END,order_lines.line_items,'[]'::jsonb))::text) AS source_hash,
      CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code
    FROM paid_orders paid
    JOIN public.orders orders ON orders.id = paid.order_id
    JOIN public.restaurants restaurant ON restaurant.id = paid.store_id
    LEFT JOIN public.red_invoice_intakes intake
      ON intake.order_id = paid.order_id
    LEFT JOIN latest_jobs job ON job.order_id=paid.order_id
    LEFT JOIN historical_entities historical_entity ON historical_entity.order_id=paid.order_id
    JOIN public.tax_entity seller
      ON seller.id = CASE
        WHEN paid.store_id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid THEN restaurant.tax_entity_id
        ELSE COALESCE(
          job.tax_entity_id,
          historical_entity.tax_entity_id,
          restaurant.tax_entity_id
        )
      END
    LEFT JOIN public.meinvoice_tax_entity_config config ON config.tax_entity_id=seller.id
    LEFT JOIN receipt_numbers receipt_number ON receipt_number.order_id=paid.order_id
    LEFT JOIN order_lines ON order_lines.order_id=paid.order_id
    WHERE seller.id <> '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
  ) SELECT * FROM report_rows;

$rows$;
REVOKE ALL ON FUNCTION public.pos_restaurant_receipt_rows_v2(date,uuid[]) FROM PUBLIC,anon,authenticated;
DO $report$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 IF strpos(d,'public.pos_restaurant_receipt_rows(')=0 THEN RAISE EXCEPTION 'INVOICE_EXPORT_REPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE replace(d,'public.pos_restaurant_receipt_rows(','public.pos_restaurant_receipt_rows_v2(');
END $report$;
CREATE FUNCTION public.refresh_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_tax_entity_id IS NULL OR cardinality(p_order_ids) NOT BETWEEN 1 AND 100
 OR p_order_ids IS NULL OR EXISTS(SELECT 1 FROM unnest(p_order_ids) x WHERE x IS NULL) OR cardinality(p_order_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_order_ids) x) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_INVALID'; END IF;
 SELECT count(*) INTO n FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id;
 IF n<>cardinality(p_order_ids) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_CHANGED'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id),
 updated AS(UPDATE public.meinvoice_jobs j SET payment_method_snapshot=s.payment_method,line_items_snapshot=s.line_items,updated_at=now()
 FROM scope s WHERE j.order_id::text=s.receipt_id AND j.tax_entity_id=p_tax_entity_id AND j.status IN('pending_manual_config','dispatch_paused','pending')
 AND j.dispatch_claim_id IS NULL AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL AND COALESCE(j.dispatch_attempts,0)=0
 AND s.payment_method<>'UNMAPPED' AND jsonb_array_length(s.line_items)>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s.line_items) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='')
 RETURNING j.id) SELECT count(*) INTO n FROM updated;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) TO authenticated;
DO $enqueue$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure) INTO d;
 IF strpos(d,'''item_type'', oi.item_type,')=0 OR strpos(d,'  WHERE oi.order_id = NEW.id')=0 THEN RAISE EXCEPTION 'INVOICE_ENQUEUE_ANCHOR_CHANGED'; END IF;
 d:=replace(d,$old$'item_type', oi.item_type,$old$,$new$'menu_item_id', oi.menu_item_id, 'invoice_profile_id', profile.id, 'misa_unit_price', tax_line.total_amount_ex_tax/NULLIF(tax_line.quantity,0), 'misa_discount_amount', 0, 'invoice_name_vi', profile.invoice_name_vi, 'misa_unit_name', profile.unit_name, 'item_type', oi.item_type,$new$);
 d:=replace(d,'  WHERE oi.order_id = NEW.id',E'  LEFT JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=oi.menu_item_id AND profile.effective_from<=now() AND (profile.effective_to IS NULL OR now()<profile.effective_to)\n  WHERE oi.order_id = NEW.id');
 EXECUTE d;
 SELECT pg_get_functiondef('public.claim_meinvoice_jobs(uuid,integer,uuid)'::regprocedure) INTO d;
 IF strpos(d,'status=''pending'' AND dispatch_claim_id IS NULL')=0 THEN RAISE EXCEPTION 'INVOICE_CLAIM_ANCHOR_CHANGED'; END IF;
 EXECUTE replace(d,$old$status='pending' AND dispatch_claim_id IS NULL$old$,$new$status='pending' AND dispatch_claim_id IS NULL AND (source_system='photo_objet_moers' OR (snapshot_version>=2 AND payment_method_snapshot<>'UNMAPPED' AND payment_method_snapshot NOT LIKE '%QR%' AND jsonb_array_length(line_items_snapshot)>0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(line_items_snapshot) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='' OR COALESCE(line->>'order_item_id','')='')))$new$);
END $enqueue$;
DO $verify$ BEGIN
 IF public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['CASH','BANKTRANSFER'])<>'TM/CK'
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'INVOICE_EXPORT_CONTRACT_DRIFT'; END IF;
END $verify$;

-- COMPONENT 20261011202000_sales_reporting_pages.sql SHA256 c2142da8d216317016537ff939c2b32fbfcc62f5ee7286886d3f72175bf66092

-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
CREATE FUNCTION public.pos_photo_receipt_rows(p_business_date date) RETURNS TABLE(
 tax_entity_id uuid,seller_tax_code text,seller_legal_name text,source_hash text,store_id uuid,store_name text,device_name text,sold_at timestamptz,amount numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH raw_scope AS MATERIALIZED(SELECT raw.* FROM public.photo_objet_sales_raw raw WHERE sale_date=p_business_date AND source_identity_version=2 AND amount>0),
 history AS MATERIALIZED(SELECT DISTINCT ON(raw.source_hash) raw.source_hash,h.tax_entity_id FROM raw_scope raw
 JOIN public.store_tax_entity_history h ON h.store_id=raw.store_id AND h.effective_from<=raw.sold_at AND (h.effective_to IS NULL OR raw.sold_at<h.effective_to)
 ORDER BY raw.source_hash,h.effective_from DESC,h.created_at DESC)
 SELECT seller.id,seller.tax_code,seller.name,raw.source_hash,raw.store_id,r.name,raw.device_name,raw.sold_at,raw.amount::numeric
 FROM raw_scope raw JOIN public.restaurants r ON r.id=raw.store_id AND r.brand_id='77000000-0000-0000-0000-000000000001'::uuid
 LEFT JOIN history h ON h.source_hash=raw.source_hash JOIN public.tax_entity seller ON seller.id=COALESCE(h.tax_entity_id,r.tax_entity_id)
 WHERE seller.id<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
$$;
REVOKE ALL ON FUNCTION public.pos_photo_receipt_rows(date) FROM PUBLIC,anon,authenticated;
-- Preserve the legacy automation response while replacing its correlated history lookup.
DO $photo$ DECLARE d text; a integer;b integer; BEGIN
 SELECT pg_get_functiondef('public.get_photo_sales_misa_exports_by_tax_entity(date)'::regprocedure) INTO d;
 a:=strpos(d,'  WITH photo_rows AS (');b:=strpos(d,'  entity_rollups AS (');
 IF a=0 OR b<=a THEN RAISE EXCEPTION 'PHOTO_EXPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE substr(d,1,a-1)||'  WITH photo_rows AS (SELECT * FROM public.pos_photo_receipt_rows(v_business_date)), '||substr(d,b);
END $photo$;
CREATE FUNCTION public.pos_daily_receipt_scope(p_business_date date) RETURNS TABLE(
 order_id uuid,store_id uuid,sold_at timestamptz,gross_sales numeric,tax_entity_id uuid,is_red_invoice boolean)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH candidates AS MATERIALIZED(SELECT DISTINCT order_id FROM public.payments WHERE is_revenue
 AND created_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND created_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 paid AS MATERIALIZED(SELECT p.order_id,p.restaurant_id,max(p.created_at) sold_at,sum(COALESCE(p.amount_portion,p.amount)) gross
 FROM public.payments p JOIN candidates c ON c.order_id=p.order_id JOIN public.orders o ON o.id=p.order_id AND o.status='completed'
 JOIN public.restaurants r ON r.id=p.restaurant_id AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 WHERE p.is_revenue AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid AND r.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
 GROUP BY p.order_id,p.restaurant_id HAVING max(p.created_at)>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND max(p.created_at)<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 historical AS MATERIALIZED(SELECT DISTINCT ON(p.order_id) p.order_id,h.tax_entity_id FROM paid p JOIN public.store_tax_entity_history h ON h.store_id=p.restaurant_id
 AND h.effective_from<=p.sold_at AND (h.effective_to IS NULL OR p.sold_at<h.effective_to) ORDER BY p.order_id,h.effective_from DESC,h.created_at DESC),
 jobs AS MATERIALIZED(SELECT DISTINCT ON(j.order_id) j.order_id,j.tax_entity_id FROM public.meinvoice_jobs j JOIN paid p ON p.order_id=j.order_id
 WHERE j.source_system='restaurant_pos' ORDER BY j.order_id,j.created_at DESC,j.id DESC)
 SELECT p.order_id,p.restaurant_id,p.sold_at,p.gross,COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id),i.id IS NOT NULL AND i.status<>'cancelled'
 FROM paid p JOIN public.restaurants r ON r.id=p.restaurant_id LEFT JOIN historical h ON h.order_id=p.order_id LEFT JOIN jobs j ON j.order_id=p.order_id
 LEFT JOIN public.red_invoice_intakes i ON i.order_id=p.order_id WHERE COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
$$;
REVOKE ALL ON FUNCTION public.pos_daily_receipt_scope(date) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_pos_daily_sales_summary(p_business_date date) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN RAISE EXCEPTION 'SALES_REPORT_DATE_INVALID'; END IF;
 WITH paid AS MATERIALIZED(SELECT * FROM public.pos_daily_receipt_scope(p_business_date)),
 restaurant AS(SELECT tax_entity_id,count(*) receipt_count,count(*) FILTER(WHERE NOT is_red_invoice) general_count,
 count(*) FILTER(WHERE is_red_invoice) red_count,sum(gross_sales) gross FROM paid GROUP BY tax_entity_id),
 tax_totals AS(SELECT p.tax_entity_id,sum(item.total_amount_ex_tax) supply,sum(item.vat_amount) vat FROM paid p
 JOIN public.order_items item ON item.order_id=p.order_id AND item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false GROUP BY p.tax_entity_id),
 day_payments AS MATERIALIZED(SELECT p.* FROM public.payments p JOIN public.restaurants r ON r.id=p.restaurant_id
 WHERE p.is_revenue AND p.created_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND p.created_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid),
 payment_entities AS MATERIALIZED(SELECT DISTINCT ON(p.id) p.id,COALESCE(h.tax_entity_id,r.tax_entity_id) tax_entity_id
 FROM day_payments p JOIN public.restaurants r ON r.id=p.restaurant_id LEFT JOIN public.store_tax_entity_history h ON h.store_id=p.restaurant_id
 AND h.effective_from<=p.created_at AND (h.effective_to IS NULL OR p.created_at<h.effective_to) ORDER BY p.id,h.effective_from DESC,h.created_at DESC),
 cash AS(SELECT e.tax_entity_id,sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='CASH') cash,
 sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='BANKTRANSFER') bank FROM day_payments p JOIN payment_entities e ON e.id=p.id GROUP BY e.tax_entity_id),
 photo AS(SELECT tax_entity_id,count(*) receipt_count,sum(amount) gross,sum(round(amount/1.08)) supply,sum(amount-round(amount/1.08)) vat
 FROM public.pos_photo_receipt_rows(p_business_date) GROUP BY tax_entity_id),
 photo_status AS(SELECT r.tax_entity_id,count(DISTINCT r.id) store_count,count(DISTINCT run.store_id) imported
 FROM public.restaurants r LEFT JOIN public.photo_objet_sales_pull_runs run ON run.store_id=r.id AND run.target_date=p_business_date AND run.collector_method='excel' AND run.status='success'
 WHERE r.brand_id='77000000-0000-0000-0000-000000000001'::uuid AND r.is_active GROUP BY r.tax_entity_id),
 closing AS(SELECT r.tax_entity_id,count(*) FILTER(WHERE d.close_source='manual') closed,count(*) stores,
 sum(CASE WHEN d.close_source='manual' THEN d.counted_cash_amount-d.opening_cash_amount END) actual_deposit,
 sum(d.cash_variance) variance,sum(d.direct_order_cash_refunds) refunds,sum(d.delivery_cash_paid) cash_paid,sum(d.delivery_cash_recovered) recovered
 FROM public.restaurants r LEFT JOIN public.daily_closings d ON d.restaurant_id=r.id AND d.closing_date=p_business_date
 WHERE r.is_active AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid GROUP BY r.tax_entity_id),
 entities AS(SELECT tax_entity_id FROM restaurant UNION SELECT tax_entity_id FROM photo UNION SELECT tax_entity_id FROM photo_status UNION SELECT tax_entity_id FROM cash UNION SELECT tax_entity_id FROM closing)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('tax_entity_id',e.tax_entity_id,'seller_tax_code',t.tax_code,'seller_legal_name',t.name,
 'restaurant_receipt_count',COALESCE(r.receipt_count,0),'general_count',COALESCE(r.general_count,0),'red_count',COALESCE(r.red_count,0),
 'restaurant_gross',COALESCE(r.gross,0),'photo_receipt_count',COALESCE(p.receipt_count,0),'photo_gross',COALESCE(p.gross,0),
 'supply',COALESCE(tax.supply,0)+COALESCE(p.supply,0),'vat',COALESCE(tax.vat,0)+COALESCE(p.vat,0),
 'restaurant_cash',COALESCE(c.cash,0),'restaurant_bank_transfer',COALESCE(c.bank,0),
 'photo_complete',COALESCE(ps.imported=ps.store_count,true),'closing_complete',COALESCE(cl.closed=cl.stores,true),
 'closing_deposit',CASE WHEN cl.closed=cl.stores THEN cl.actual_deposit ELSE NULL END,
 'cash_variance',COALESCE(cl.variance,0),'cash_refunds',COALESCE(cl.refunds,0),'delivery_cash_paid',COALESCE(cl.cash_paid,0),'delivery_cash_recovered',COALESCE(cl.recovered,0),
 'bank',CASE WHEN a.id IS NULL THEN NULL ELSE jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder) END)
 ORDER BY t.tax_code),'[]'::jsonb) INTO result FROM entities e JOIN public.tax_entity t ON t.id=e.tax_entity_id
 LEFT JOIN restaurant r ON r.tax_entity_id=e.tax_entity_id LEFT JOIN tax_totals tax ON tax.tax_entity_id=e.tax_entity_id LEFT JOIN photo p ON p.tax_entity_id=e.tax_entity_id
 LEFT JOIN cash c ON c.tax_entity_id=e.tax_entity_id LEFT JOIN photo_status ps ON ps.tax_entity_id=e.tax_entity_id LEFT JOIN closing cl ON cl.tax_entity_id=e.tax_entity_id
 LEFT JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=e.tax_entity_id AND a.retired_at IS NULL AND a.effective_from<=now()
 WHERE e.tax_entity_id<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
 RETURN jsonb_build_object('business_date',p_business_date,'deposit_date',p_business_date+1,'as_of',statement_timestamp(),'entities',result);
END $$;
REVOKE ALL ON FUNCTION public.get_pos_daily_sales_summary(date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_daily_sales_summary(date) TO authenticated;

CREATE FUNCTION public.get_pos_daily_sales_export_page(p_business_date date,p_tax_entity_id uuid,p_source_system text,
 p_after_time timestamptz DEFAULT NULL,p_after_id text DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;ids uuid[];
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
 OR p_tax_entity_id IS NULL OR p_source_system NOT IN('restaurant_pos','photo_objet_moers') OR p_source_system IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
 OR (p_after_time IS NULL)<>(p_after_id IS NULL) THEN RAISE EXCEPTION 'SALES_EXPORT_PAGE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurant_daily_sales_finalizations WHERE business_date=p_business_date AND status<>'finalized') THEN RAISE EXCEPTION 'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED'; END IF;
 IF p_source_system='restaurant_pos' THEN
 SELECT array_agg(order_id ORDER BY sold_at,order_id) INTO ids FROM(SELECT order_id,sold_at FROM public.pos_daily_receipt_scope(p_business_date)
 WHERE tax_entity_id=p_tax_entity_id AND (p_after_time IS NULL OR (sold_at,order_id::text)>(p_after_time,p_after_id)) ORDER BY sold_at,order_id LIMIT p_limit) scope;
 SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.receipt_id),'[]'::jsonb) INTO result
 FROM public.pos_restaurant_receipt_rows_v2(p_business_date,COALESCE(ids,'{}'::uuid[])) r WHERE r.tax_entity_id=p_tax_entity_id;
 ELSE
 SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.source_hash),'[]'::jsonb) INTO result FROM(SELECT * FROM public.pos_photo_receipt_rows(p_business_date)
 WHERE tax_entity_id=p_tax_entity_id AND (p_after_time IS NULL OR (sold_at,source_hash)>(p_after_time,p_after_id)) ORDER BY sold_at,source_hash LIMIT p_limit) r;
 END IF;
 RETURN jsonb_build_object('business_date',p_business_date,'tax_entity_id',p_tax_entity_id,'source_system',p_source_system,'rows',result);
END $$;
REVOKE ALL ON FUNCTION public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer) TO authenticated;
DO $verify$ BEGIN
 IF has_function_privilege('anon','public.get_pos_daily_sales_summary(date)','EXECUTE') OR has_function_privilege('anon','public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)','EXECUTE') THEN RAISE EXCEPTION 'SALES_REPORT_SCOPE_DRIFT'; END IF;
END $verify$;

-- COMPONENT 20261011203000_invoice_contacts_payment_methods.sql SHA256 31d169d7c9c08a4a4a40edecb52d96a12309494f103a416339d15217f4bd56cd

-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
-- Preserve method identity: VNPAY has no recorded funding route, Voucher is
-- recorded tender (not a new discount), and Credit Sale remains unpaid tender.
CREATE OR REPLACE FUNCTION public.misa_payment_code_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value),
 labels AS(SELECT DISTINCT CASE method WHEN 'CASH' THEN 'TM' WHEN 'BANKTRANSFER' THEN 'CK'
 WHEN 'CREDITCARD' THEN 'Thẻ quốc tế' WHEN 'ATM' THEN 'Thẻ ATM' WHEN 'VNPAY' THEN 'VNPAY'
 WHEN 'VOUCHER' THEN 'Voucher' WHEN 'CREDITSALE' THEN 'Chưa thu tiền' ELSE 'Ví điện tử' END label FROM methods)
 SELECT CASE WHEN count(*)=0 OR bool_or(method IS NULL OR method NOT IN('CASH','BANKTRANSFER','CREDITCARD','ATM','MOMO','ZALOPAY','SHOPEEPAY','VNPAY','VOUCHER','CREDITSALE','OTHER','EPAY','PAY')) THEN 'UNMAPPED'
 WHEN count(*)=2 AND bool_and(method IN('CASH','BANKTRANSFER')) THEN 'TM/CK'
 ELSE (SELECT string_agg(label,'/' ORDER BY label COLLATE "C") FROM labels) END FROM methods;
$$;
CREATE FUNCTION public.misa_payment_kind_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=public,pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value)
 SELECT CASE WHEN public.misa_payment_code_for_methods(p_methods)='UNMAPPED' THEN 'UNMAPPED'
 WHEN count(*)>1 THEN 'MIXED' ELSE max(CASE method WHEN 'CREDITCARD' THEN 'CARD' WHEN 'ATM' THEN 'CARD'
 WHEN 'MOMO' THEN 'EWALLET' WHEN 'ZALOPAY' THEN 'EWALLET' WHEN 'SHOPEEPAY' THEN 'EWALLET'
 WHEN 'OTHER' THEN 'EWALLET' WHEN 'EPAY' THEN 'EWALLET' WHEN 'PAY' THEN 'EWALLET' WHEN 'VNPAY' THEN 'GATEWAY' ELSE method END) END FROM methods;
$$;
REVOKE ALL ON FUNCTION public.misa_payment_kind_for_methods(text[]) FROM PUBLIC,anon,authenticated;

-- Pure contact selection; no queries, extra RPCs, or inferred customer data.
CREATE FUNCTION public.misa_buyer_contact_snapshot(p_intake_id uuid,p_email text,p_phone text,p_snapshot jsonb,p_locked boolean) RETURNS jsonb
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('email',btrim(COALESCE(CASE WHEN p_locked THEN p_snapshot->>'email'
 WHEN p_intake_id IS NOT NULL THEN p_email ELSE p_snapshot->>'email' END,'')),
 'phone',btrim(COALESCE(CASE WHEN p_locked THEN p_snapshot->>'phone'
 WHEN p_intake_id IS NOT NULL THEN p_phone ELSE p_snapshot->>'phone' END,'')));
$$;
REVOKE ALL ON FUNCTION public.misa_buyer_contact_snapshot(uuid,text,text,jsonb,boolean) FROM PUBLIC,anon,authenticated;

-- Previous archives have no recoverable buyer snapshot; leave those NULL.
ALTER TABLE public.meinvoice_job_snapshot_versions ADD COLUMN buyer_snapshot jsonb;
CREATE OR REPLACE FUNCTION public.preserve_meinvoice_export_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF OLD.payment_method_snapshot IS NOT DISTINCT FROM NEW.payment_method_snapshot AND OLD.line_items_snapshot IS NOT DISTINCT FROM NEW.line_items_snapshot
 AND OLD.payment_summary IS NOT DISTINCT FROM NEW.payment_summary AND OLD.buyer_snapshot IS NOT DISTINCT FROM NEW.buyer_snapshot THEN RETURN NEW; END IF;
 IF OLD.status IN('sent_to_misa','sent_to_tax_authority','valid_invoice','resolved') OR OLD.misa_ref_id IS NOT NULL OR OLD.invoice_number IS NOT NULL OR OLD.dispatch_claim_id IS NOT NULL OR COALESCE(OLD.dispatch_attempts,0)>0 THEN RAISE EXCEPTION 'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE'; END IF;
 INSERT INTO public.meinvoice_job_snapshot_versions(job_id,snapshot_version,payment_method_snapshot,line_items_snapshot,payment_summary,buyer_snapshot,source_hash)
 VALUES(OLD.id,OLD.snapshot_version,OLD.payment_method_snapshot,OLD.line_items_snapshot,OLD.payment_summary,OLD.buyer_snapshot,
 md5(jsonb_build_object('method',OLD.payment_method_snapshot,'items',OLD.line_items_snapshot,'payments',OLD.payment_summary,'buyer',OLD.buyer_snapshot)::text)) ON CONFLICT DO NOTHING;
 NEW.snapshot_version:=OLD.snapshot_version+1; RETURN NEW;
END $$;

DO $receipt$ DECLARE d text; anchor text; BEGIN
 SELECT pg_get_functiondef('public.pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure) INTO d;
 anchor:='candidate.line_items_snapshot,candidate.snapshot_version';
 IF strpos(d,anchor)=0 OR strpos(d,'COALESCE(intake.buyer_email, '''') AS buyer_email')=0
 OR strpos(d,'COALESCE(intake.buyer_phone, '''') AS buyer_phone')=0
 OR strpos(d,'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id')=0
 OR strpos(d,'''methods'',paid.payment_methods,')=0
 OR strpos(d,$old$CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code$old$)=0
 THEN RAISE EXCEPTION 'INVOICE_CONTACT_EXPORT_ANCHOR_CHANGED'; END IF;
 d:=replace(d,anchor,anchor||',candidate.buyer_snapshot,(candidate.status IN(''sent_to_misa'',''sent_to_tax_authority'',''valid_invoice'',''resolved'') OR candidate.misa_ref_id IS NOT NULL OR candidate.invoice_number IS NOT NULL OR candidate.dispatch_claim_id IS NOT NULL OR COALESCE(candidate.dispatch_attempts,0)>0) contact_locked');
 d:=replace(d,'COALESCE(intake.buyer_email, '''') AS buyer_email','contacts.buyer->>''email'' AS buyer_email');
 d:=replace(d,'COALESCE(intake.buyer_phone, '''') AS buyer_phone','contacts.buyer->>''phone'' AS buyer_phone');
 d:=replace(d,'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id',
 'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id CROSS JOIN LATERAL (SELECT public.misa_buyer_contact_snapshot(intake.id,intake.buyer_email,intake.buyer_phone,job.buyer_snapshot,COALESCE(job.contact_locked,false)) buyer) contacts');
 d:=replace(d,'''methods'',paid.payment_methods,','''methods'',paid.payment_methods,''buyer_contacts'',contacts.buyer,');
 d:=replace(d,$old$CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code$old$,
 'public.misa_payment_kind_for_methods(paid.payment_methods) AS payment_code');
 IF strpos(d,'contacts.buyer->>''email'' AS buyer_email')=0 OR strpos(d,'contacts.buyer->>''phone'' AS buyer_phone')=0
 OR strpos(d,'''buyer_contacts'',contacts.buyer,')=0
 OR strpos(d,'public.misa_payment_kind_for_methods(paid.payment_methods) AS payment_code')=0
 THEN RAISE EXCEPTION 'INVOICE_CONTACT_EXPORT_PATCH_INCOMPLETE'; END IF;
 EXECUTE d;
END $receipt$;

CREATE OR REPLACE FUNCTION public.refresh_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_tax_entity_id IS NULL
 OR cardinality(p_order_ids) NOT BETWEEN 1 AND 100 OR p_order_ids IS NULL OR EXISTS(SELECT 1 FROM unnest(p_order_ids) x WHERE x IS NULL)
 OR cardinality(p_order_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_order_ids) x) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_INVALID'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids))
 SELECT count(*) INTO n FROM scope WHERE tax_entity_id=p_tax_entity_id;
 IF n<>cardinality(p_order_ids) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_CHANGED'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id),
 updates AS(SELECT j.id,s.payment_method,s.line_items,
 j.buyer_snapshot||jsonb_build_object('email',s.buyer_email,'phone',s.buyer_phone) buyer,
 j.payment_summary||jsonb_build_object('methods',to_jsonb(s.payment_methods)) payments FROM public.meinvoice_jobs j JOIN scope s ON j.order_id::text=s.receipt_id
 WHERE j.tax_entity_id=p_tax_entity_id AND j.status IN('pending_manual_config','dispatch_paused','pending')
 AND j.dispatch_claim_id IS NULL AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL AND COALESCE(j.dispatch_attempts,0)=0
 AND s.payment_method<>'UNMAPPED' AND jsonb_array_length(s.line_items)>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s.line_items) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='')),
 updated AS(UPDATE public.meinvoice_jobs j SET payment_method_snapshot=u.payment_method,line_items_snapshot=u.line_items,buyer_snapshot=u.buyer,payment_summary=u.payments,updated_at=now()
 FROM updates u WHERE j.id=u.id AND ROW(j.payment_method_snapshot,j.line_items_snapshot,j.buyer_snapshot,j.payment_summary) IS DISTINCT FROM ROW(u.payment_method,u.line_items,u.buyer,u.payments) RETURNING j.id)
 SELECT count(*) INTO n FROM updated;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) TO authenticated;
DO $verify$ BEGIN
 IF public.misa_payment_code_for_methods(ARRAY['MOMO'])<>'Ví điện tử' OR public.misa_payment_code_for_methods(ARRAY['VNPAY'])<>'VNPAY'
 OR public.misa_payment_kind_for_methods(ARRAY['VOUCHER'])<>'VOUCHER' OR public.misa_payment_kind_for_methods(ARRAY['CREDITSALE'])<>'CREDITSALE'
 OR public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['QR'])<>'UNMAPPED'
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'INVOICE_CONTACT_PAYMENT_CONTRACT_DRIFT'; END IF;
END $verify$;

DO $final$
BEGIN
 IF to_regclass('public.tax_entity_collection_accounts') IS NULL OR to_regclass('public.menu_invoice_profiles') IS NULL
 OR to_regclass('public.meinvoice_job_snapshot_versions') IS NULL THEN RAISE EXCEPTION 'CORPORATE_RELEASE_TABLES_MISSING'; END IF;
 IF public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['CASH','BANKTRANSFER'])<>'TM/CK'
 OR public.misa_payment_code_for_methods(ARRAY['MOMO'])<>'Ví điện tử' OR public.misa_payment_kind_for_methods(ARRAY['VNPAY'])<>'GATEWAY'
 OR public.misa_payment_kind_for_methods(ARRAY['VOUCHER'])<>'VOUCHER' OR public.misa_payment_kind_for_methods(ARRAY['CREDITSALE'])<>'CREDITSALE'
 OR public.misa_payment_code_for_methods(ARRAY['QR'])<>'UNMAPPED' THEN RAISE EXCEPTION 'CORPORATE_RELEASE_PAYMENT_CONTRACT_CHANGED'; END IF;
 IF has_function_privilege('anon','public.get_store_collection_bank(uuid)','EXECUTE')
 OR has_function_privilege('anon','public.get_pos_daily_sales_summary(date)','EXECUTE')
 OR has_function_privilege('anon','public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)','EXECUTE')
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ANONYMOUS_ACCESS'; END IF;
 RAISE NOTICE 'CORPORATE_SALES_CONTACTS_ATOMIC_RELEASE=PASS';
END $final$;
COMMIT;
