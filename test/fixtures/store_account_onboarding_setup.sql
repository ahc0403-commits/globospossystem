ALTER TABLE restaurants ADD COLUMN short_code text;
ALTER TABLE users ADD COLUMN restaurant_id uuid REFERENCES restaurants(id), ADD COLUMN primary_store_id uuid REFERENCES restaurants(id),ADD COLUMN brand_id uuid REFERENCES brands(id),ADD COLUMN full_name text,ADD COLUMN account_type text,ADD COLUMN fixed_account_code text UNIQUE,ADD COLUMN must_change_password boolean NOT NULL DEFAULT true;
ALTER TABLE users ADD CONSTRAINT users_auth_id_unique UNIQUE(auth_id);
CREATE TABLE store_fixed_account_requirements(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),store_id uuid REFERENCES restaurants(id),account_code text,account_type text,role text,display_name text,scope text,provisioned_user_id uuid REFERENCES users(id),is_active boolean DEFAULT true,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),UNIQUE(store_id,account_code));
CREATE TABLE user_brand_access(user_id uuid REFERENCES users(id),brand_id uuid REFERENCES brands(id),is_active boolean,granted_by uuid,UNIQUE(user_id,brand_id));
CREATE TABLE user_store_access(user_id uuid REFERENCES users(id),store_id uuid REFERENCES restaurants(id),is_primary boolean DEFAULT false,is_active boolean DEFAULT true,source_type text,granted_by uuid,UNIQUE(user_id,store_id,source_type));
CREATE TABLE user_tax_entity_access(user_id uuid,tax_entity_id uuid,is_active boolean);
CREATE TABLE emergency_station_assignments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,user_id uuid,station_type text,floor_label text,is_active boolean,updated_at timestamptz DEFAULT now(),CONSTRAINT emergency_station_floor_contract CHECK ((station_type='floor' AND floor_label IN('1F','2F')) OR (station_type<>'floor' AND floor_label IS NULL)),UNIQUE(restaurant_id,user_id));
CREATE TABLE emergency_order_queue(floor_label text CHECK(floor_label IN('1F','2F')));
CREATE TABLE kds_shadow_health(floor_key text CHECK(floor_key IN('','1F','2F')));
CREATE TABLE kds_change_log(target_floor_label text CHECK(target_floor_label IS NULL OR target_floor_label IN('1F','2F')));
CREATE TABLE emergency_tray_floor_batch_actions(floor_label text CHECK(floor_label IN('1F','2F')));
-- Cron scheduling is verified structurally here; this isolated DB has no network
-- worker or Vault. Production preflight verifies the actual extensions and secret.
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobid serial,jobname text,active boolean DEFAULT true,schedule text,command text);
CREATE FUNCTION cron.schedule(text,text,text) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO cron.job(jobname,schedule,command) VALUES($1,$2,$3) RETURNING jobid::bigint $$;
CREATE FUNCTION cron.unschedule(text) RETURNS boolean LANGUAGE sql AS $$ WITH d AS(DELETE FROM cron.job WHERE jobname=$1 RETURNING *) SELECT count(*)>0 FROM d $$;

CREATE TABLE legal_entity_fixed_account_requirements(tax_entity_id uuid,provisioned_user_id uuid,is_active boolean,role text);
CREATE TABLE procurement_role_roster(restaurant_id uuid,system text,subject_id uuid,person_id uuid,stage text,display_name text,valid_from timestamptz,valid_until timestamptz,reason text,assigned_by jsonb,account_kind text,UNIQUE(restaurant_id,system,subject_id,stage));
CREATE TABLE procurement_store_onboarding(restaurant_id uuid PRIMARY KEY,office_connected boolean NOT NULL DEFAULT false,readiness jsonb NOT NULL DEFAULT '{}',updated_at timestamptz DEFAULT now());
CREATE TABLE procurement_store_policies(restaurant_id uuid PRIMARY KEY,enabled boolean,two_stage_required boolean,three_stage_required boolean,new_requests_enabled boolean);
