BEGIN;
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
COMMIT;
