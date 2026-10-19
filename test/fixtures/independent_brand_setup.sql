DO $$ BEGIN
  IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
END $$;
-- auth.uid() and auth schema are supplied by the isolated Supabase image.
CREATE TABLE users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),auth_id uuid,role text,is_active boolean);
CREATE TABLE companies(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL);
CREATE TABLE brand_master(id uuid PRIMARY KEY,company_id uuid NOT NULL REFERENCES companies,name text NOT NULL);
CREATE TABLE tax_entity(id uuid PRIMARY KEY,name text NOT NULL,owner_type text NOT NULL);
CREATE TABLE brands(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,code text NOT NULL UNIQUE,
  company_id uuid REFERENCES companies,brand_master_id uuid NOT NULL REFERENCES brand_master,
  service_charge_enabled boolean NOT NULL DEFAULT false,service_charge_rate numeric NOT NULL DEFAULT 0,
  management_model text NOT NULL DEFAULT 'store_managed',brand_manager_slots integer NOT NULL DEFAULT 1
);
CREATE TABLE tax_entity_brands(
  tax_entity_id uuid REFERENCES tax_entity,brand_id uuid REFERENCES brands,
  created_by uuid,PRIMARY KEY(tax_entity_id,brand_id)
);
CREATE TABLE restaurants(
  id uuid PRIMARY KEY,name text,address text,slug text UNIQUE,operation_mode text,per_person_charge numeric,
  tax_entity_id uuid NOT NULL,brand_id uuid NOT NULL,store_type text,is_active boolean,created_at timestamptz,
  FOREIGN KEY(tax_entity_id,brand_id) REFERENCES tax_entity_brands
);
CREATE INDEX ON restaurants(brand_id);
CREATE TABLE audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE TABLE store_tax_entity_history(
  store_id uuid,tax_entity_id uuid,effective_from timestamptz,reason text,created_by uuid
);
CREATE FUNCTION link_office_pending_store_for_pos_store_v2(uuid,text,uuid,uuid,text,uuid)
RETURNS uuid LANGUAGE sql AS $$ SELECT NULL::uuid $$;
ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public,auth TO authenticated,anon;
GRANT SELECT,INSERT ON brands TO authenticated;
INSERT INTO users(auth_id,role,is_active) VALUES
 ('10000000-0000-4000-8000-000000000001','super_admin',true),
 ('10000000-0000-4000-8000-000000000002','admin',true),
 ('10000000-0000-4000-8000-000000000003','super_admin',false);
INSERT INTO companies(id,name) VALUES('20000000-0000-4000-8000-000000000001','Organization');
INSERT INTO brand_master VALUES('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Brand group');
INSERT INTO tax_entity VALUES
 ('40000000-0000-4000-8000-000000000001','Internal company','internal'),
 ('40000000-0000-4000-8000-000000000002','External company','external');

CREATE FUNCTION public.brand_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'ASSERTION_FAILED: %', message; END IF; END $$;

CREATE FUNCTION public.brand_expect_error(statement text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(expected in SQLERRM)>0 THEN RETURN; END IF;
    RAISE;
  END;
  RAISE EXCEPTION 'EXPECTED_ERROR_NOT_RAISED: %',expected;
END $$;
GRANT EXECUTE ON FUNCTION public.brand_assert(boolean,text),public.brand_expect_error(text,text) TO authenticated,anon;
