-- =============================================================================
-- Phase 2 Step 4 — 11 new WeTax-infrastructure tables (DDL only)
-- Migration: 20260412190000_phase_2_step_4_wetax_tables.sql
-- Scope authority: stage1_scope_v1.3.md Section 3.1, Appendix A.3
-- Target project: ynriuoomotxuwhuxxmhj (globospossystem)
-- Assumptions confirmed:
--   A1: store_id column name (new vocabulary; REFERENCES restaurants.id physically)
--   A2: password_value bytea + password_format TEXT+CHECK
--   A3: system_config seeded with 4 Stage 1 values
--   A4: einvoice_jobs.ref_id UUIDv7 CHECK regex enforced
--   A5: RLS ENABLED on all 11 tables; no policies (Step 6)
--   A6: single migration file, atomic apply
-- Rules:
--   - No existing table modifications (Step 5)
--   - No RLS policies (Step 6)
--   - No edge functions (Step 7)
--   - All enums via TEXT + CHECK (consistent with existing schema pattern)
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. brand_master — internal/external grouping of brands
-- Hierarchy position: companies (hq) → brand_master → brands → restaurants
-- No FKs except to companies (hq).
-- ===========================================================================
CREATE TABLE public.brand_master (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid        NOT NULL REFERENCES public.companies(id),
  name        text        NOT NULL,
  type        text        NOT NULL CHECK (type IN ('internal', 'external')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.brand_master IS 'Logical grouping of brands by ownership type. Sits between hq (companies) and brands in the operational hierarchy.';
COMMENT ON COLUMN public.brand_master.id         IS 'Primary key.';
COMMENT ON COLUMN public.brand_master.company_id IS 'FK to companies (hq). One brand_master belongs to one hq.';
COMMENT ON COLUMN public.brand_master.name       IS 'Human-readable label for this brand group.';
COMMENT ON COLUMN public.brand_master.type       IS 'internal = GLOBOSVN directly operated; external = SaaS client company.';
COMMENT ON COLUMN public.brand_master.created_at IS 'Row creation timestamp.';
COMMENT ON COLUMN public.brand_master.updated_at IS 'Last update timestamp.';

ALTER TABLE public.brand_master ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 2. tax_entity — legal seller entity with a unique Vietnamese tax code
-- Tax axis anchor. One store → one active tax_entity at a time (I1).
-- No FKs.
-- ===========================================================================
CREATE TABLE public.tax_entity (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_code           text        NOT NULL UNIQUE,
  name               text        NOT NULL,
  owner_type         text        NOT NULL CHECK (owner_type IN ('internal', 'external')),
  einvoice_provider  text        NOT NULL DEFAULT 'wetax' CHECK (einvoice_provider IN ('wetax')),
  pos_key            text,
  declaration_status text,
  res_key            text,
  wetax_end_point    text,
  data_source        text        NOT NULL DEFAULT 'VNPT_EPAY',
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.tax_entity IS 'Legal seller entity registered with Vietnamese tax authority. Tax axis anchor: store.tax_entity_id points here. Invariants I1 (one active per store), I2 (snapshots on jobs), I10 (declaration_status gate).';
COMMENT ON COLUMN public.tax_entity.id                IS 'Primary key.';
COMMENT ON COLUMN public.tax_entity.tax_code          IS 'Vietnamese tax code (mã số thuế). Unique.';
COMMENT ON COLUMN public.tax_entity.name              IS 'Legal company name as registered with tax authority.';
COMMENT ON COLUMN public.tax_entity.owner_type        IS 'internal = GLOBOSVN own entity; external = SaaS client entity.';
COMMENT ON COLUMN public.tax_entity.einvoice_provider IS 'E-invoice provider. Only wetax in Stage 1.';
COMMENT ON COLUMN public.tax_entity.pos_key           IS 'POS key from WT01 seller-info. Used in CQT code composition.';
COMMENT ON COLUMN public.tax_entity.declaration_status IS 'Declaration status from WT01. Must be 5 (Accepted) before dispatch proceeds (Invariant I10).';
COMMENT ON COLUMN public.tax_entity.res_key           IS 'Returned by agency/sellers registration. Identifies the seller in WeTax.';
COMMENT ON COLUMN public.tax_entity.wetax_end_point   IS 'WeTax endpoint URL for this entity. Used for portal lookup_url composition.';
COMMENT ON COLUMN public.tax_entity.data_source       IS 'Data source identifier. Fixed to VNPT_EPAY in Stage 1.';
COMMENT ON COLUMN public.tax_entity.created_at        IS 'Row creation timestamp.';
COMMENT ON COLUMN public.tax_entity.updated_at        IS 'Last update timestamp.';

ALTER TABLE public.tax_entity ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 3. einvoice_shop — WeTax-registered shop under a tax_entity
-- FK to tax_entity.
-- ===========================================================================
CREATE TABLE public.einvoice_shop (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_entity_id      uuid        NOT NULL REFERENCES public.tax_entity(id),
  provider_shop_code text        NOT NULL,
  shop_name          text        NOT NULL,
  templates          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tax_entity_id, provider_shop_code)
);

COMMENT ON TABLE  public.einvoice_shop IS 'WeTax-registered shop under a tax_entity. Represents one physical sales point in WeTax. Populated from WT01 seller-info.';
COMMENT ON COLUMN public.einvoice_shop.id                 IS 'Primary key.';
COMMENT ON COLUMN public.einvoice_shop.tax_entity_id      IS 'FK to tax_entity. The legal seller this shop belongs to.';
COMMENT ON COLUMN public.einvoice_shop.provider_shop_code IS 'Shop code assigned by WeTax from WT01.';
COMMENT ON COLUMN public.einvoice_shop.shop_name          IS 'Human-readable shop name as registered with WeTax.';
COMMENT ON COLUMN public.einvoice_shop.templates          IS 'JSONB array of {form_no, serial_no, status_code} from WT01. Only templates with status_code=1 (Using) are eligible for dispatch (Invariant I9).';
COMMENT ON COLUMN public.einvoice_shop.created_at         IS 'Row creation timestamp.';
COMMENT ON COLUMN public.einvoice_shop.updated_at         IS 'Last update timestamp.';

ALTER TABLE public.einvoice_shop ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 4. partner_credentials — Agency master credential for WeTax
-- No FKs. Singleton per data_source in Stage 1 (Invariant I4).
-- password_value is envelope-encrypted at rest (L1). UNIQUE(data_source).
-- ===========================================================================
CREATE TABLE public.partner_credentials (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  data_source      text        NOT NULL UNIQUE DEFAULT 'VNPT_EPAY',
  auth_mode        text        NOT NULL DEFAULT 'password_jwt'
                               CHECK (auth_mode IN ('password_jwt', 'api_key')),
  user_id          text        NOT NULL,
  password_value   bytea       NOT NULL,
  password_format  text        NOT NULL DEFAULT 'plaintext'
                               CHECK (password_format IN ('plaintext', 'aes256_ciphertext')),
  kek_version      int         NOT NULL DEFAULT 1,
  last_verified_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.partner_credentials IS 'Single Agency master credential for WeTax. L4 envelope encryption. Singleton per data_source (I4). Only wetax-dispatcher edge function may read this table (enforced by RLS in Step 6).';
COMMENT ON COLUMN public.partner_credentials.id               IS 'Primary key.';
COMMENT ON COLUMN public.partner_credentials.data_source      IS 'Data source identifier. VNPT_EPAY only in Stage 1. UNIQUE — at most one credential per provider.';
COMMENT ON COLUMN public.partner_credentials.auth_mode        IS 'Auth mode. password_jwt in Stage 1. api_key reserved for future migration without schema change.';
COMMENT ON COLUMN public.partner_credentials.user_id          IS 'WeTax partner login username. Plaintext (low sensitivity).';
COMMENT ON COLUMN public.partner_credentials.password_value   IS 'Envelope-encrypted credential bytes. Inner plaintext is either the raw password or a pre-encrypted AES256 ciphertext depending on password_format.';
COMMENT ON COLUMN public.partner_credentials.password_format  IS 'plaintext = raw password forwarded to WT00; aes256_ciphertext = AES256 pre-encrypted string forwarded verbatim. Envelope encryption (L1) applies in both modes.';
COMMENT ON COLUMN public.partner_credentials.kek_version      IS 'Key Encryption Key version. Tracks KEK rotations via Supabase Vault.';
COMMENT ON COLUMN public.partner_credentials.last_verified_at IS 'Last successful WT00 authentication with this credential.';
COMMENT ON COLUMN public.partner_credentials.created_at       IS 'Row creation timestamp.';
COMMENT ON COLUMN public.partner_credentials.updated_at       IS 'Last update timestamp.';

ALTER TABLE public.partner_credentials ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 5. wetax_reference_values — Cached WeTax commons reference data
-- No FKs. Composite PK (category, code).
-- ===========================================================================
CREATE TABLE public.wetax_reference_values (
  category   text        NOT NULL CHECK (category IN ('payment-methods', 'tax-rates', 'currency')),
  code       text        NOT NULL,
  label      text        NOT NULL,
  extra_data jsonb,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (category, code)
);

COMMENT ON TABLE  public.wetax_reference_values IS 'Cached WeTax commons reference data. Fetched at onboarding from commons/payment-methods, commons/tax-rates, commons/currency. Drives POS UI dropdowns. Refreshed weekly.';
COMMENT ON COLUMN public.wetax_reference_values.category   IS 'Reference data category matching the WeTax commons/* endpoint path.';
COMMENT ON COLUMN public.wetax_reference_values.code       IS 'Reference code value from WeTax.';
COMMENT ON COLUMN public.wetax_reference_values.label      IS 'Human-readable display label (e.g. TM/CK for cash/transfer).';
COMMENT ON COLUMN public.wetax_reference_values.extra_data IS 'Additional fields from WeTax response for specific integration needs.';
COMMENT ON COLUMN public.wetax_reference_values.fetched_at IS 'Timestamp when this value was last fetched from WeTax.';

ALTER TABLE public.wetax_reference_values ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 6. system_config — Runtime adjustable WeTax integration flags
-- No FKs (updated_by nullable: seeded rows have no user).
-- Seeded with 4 Stage 1 values per scope v1.3 Section 3.1.
-- ===========================================================================
CREATE TABLE public.system_config (
  key        text        PRIMARY KEY,
  value      text        NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid        REFERENCES public.users(id)
);

COMMENT ON TABLE  public.system_config IS 'Key-value runtime configuration for WeTax dispatcher. Flags here change dispatcher behavior without code deployment. Updates via SQL UPDATE by super admin. See scope v1.3 Section 3.1 and Appendix B for activation procedure.';
COMMENT ON COLUMN public.system_config.key         IS 'Configuration key. Primary key.';
COMMENT ON COLUMN public.system_config.value       IS 'Configuration value (text; parse on read in application code).';
COMMENT ON COLUMN public.system_config.description IS 'Human-readable explanation of what this flag controls and its valid values.';
COMMENT ON COLUMN public.system_config.updated_at  IS 'Timestamp of last update.';
COMMENT ON COLUMN public.system_config.updated_by  IS 'FK to users. NULL for system-seeded rows. Tracks which super admin changed the value.';

INSERT INTO public.system_config (key, value, description) VALUES
  ('wetax_polling_enabled',
   'false',
   'WT06 polling worker gate. false=disabled (default; apitest WT06 broken per Phase 2 Step 1 audit). Flip to true after vendor fix confirmed (scope Appendix B).'),
  ('wetax_dispatch_enabled',
   'true',
   'sendOrderInfo dispatch gate. false=emergency stop for vendor outages. Dispatcher skips all pending jobs when false.'),
  ('wetax_request_einvoice_max_retries',
   '5',
   'Max requestEinvoiceInfo retry attempts before job enters failed_terminal. Covers apitest POS ID not found bug (adaptation point 3).'),
  ('wetax_request_einvoice_backoff_seconds',
   '0,3,10,30,60',
   'Comma-separated retry intervals (seconds) for requestEinvoiceInfo backoff. Index matches retry_count: 0=immediate,1=3s,2=10s,3=30s,4=60s.');

ALTER TABLE public.system_config ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 7. b2b_buyer_cache — POS-local B2B buyer info for red invoice requests
-- FK: store_id → restaurants(id) [new vocabulary, physical FK to restaurants]
-- FK: tax_entity_id → tax_entity(id) [denormalized, enables Tier B lookup]
-- Composite PK: (store_id, buyer_tax_code).
-- ===========================================================================
CREATE TABLE public.b2b_buyer_cache (
  store_id           uuid        NOT NULL REFERENCES public.restaurants(id),
  buyer_tax_code     text        NOT NULL,
  tax_id             text        NOT NULL GENERATED ALWAYS AS (buyer_tax_code) STORED,
  tax_company_name   text,
  tax_address        text,
  tax_buyer_name     text,
  receiver_email     text        NOT NULL,
  receiver_email_cc  text,
  first_used_at      timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz NOT NULL DEFAULT now(),
  use_count          int         NOT NULL DEFAULT 1,
  email_bounce_count int         NOT NULL DEFAULT 0,
  last_verified_at   timestamptz,
  tax_entity_id      uuid        REFERENCES public.tax_entity(id),
  PRIMARY KEY (store_id, buyer_tax_code)
);

COMMENT ON TABLE  public.b2b_buyer_cache IS 'POS-local B2B buyer cache. Drives 2-tier autocomplete on red invoice request form: Tier A (current store), Tier B (same tax_entity). Populated from form entries and WT09 auto-fill.';
COMMENT ON COLUMN public.b2b_buyer_cache.store_id           IS 'FK to restaurants.id. Column named store_id (new vocabulary) — no legacy code reads this table.';
COMMENT ON COLUMN public.b2b_buyer_cache.buyer_tax_code     IS 'Buyer Vietnamese tax code. Part of composite PK.';
COMMENT ON COLUMN public.b2b_buyer_cache.tax_id             IS 'Generated alias for buyer_tax_code. Kept for field-name alignment with requestEinvoiceInfo payload schema.';
COMMENT ON COLUMN public.b2b_buyer_cache.tax_company_name   IS 'Legal company name. Auto-filled from WT09 on first entry.';
COMMENT ON COLUMN public.b2b_buyer_cache.tax_address        IS 'Registered address. Auto-filled from WT09.';
COMMENT ON COLUMN public.b2b_buyer_cache.tax_buyer_name     IS 'Contact person name. Optional.';
COMMENT ON COLUMN public.b2b_buyer_cache.receiver_email     IS 'Primary email for red invoice delivery. Required — requestEinvoiceInfo will not proceed without this.';
COMMENT ON COLUMN public.b2b_buyer_cache.receiver_email_cc  IS 'Optional CC email for red invoice delivery.';
COMMENT ON COLUMN public.b2b_buyer_cache.first_used_at      IS 'When this buyer was first registered at this store.';
COMMENT ON COLUMN public.b2b_buyer_cache.last_used_at       IS 'Last red invoice request for this buyer at this store.';
COMMENT ON COLUMN public.b2b_buyer_cache.use_count          IS 'Total red invoice requests for this buyer at this store.';
COMMENT ON COLUMN public.b2b_buyer_cache.email_bounce_count IS 'Email delivery failures from WT06 email_status feedback.';
COMMENT ON COLUMN public.b2b_buyer_cache.last_verified_at   IS 'Last time buyer data was confirmed against WT09 or manually.';
COMMENT ON COLUMN public.b2b_buyer_cache.tax_entity_id      IS 'Denormalized from store at insert time. Enables Tier B cross-store lookup within same tax_entity.';

ALTER TABLE public.b2b_buyer_cache ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 8. store_tax_entity_history — Append-only store ↔ tax_entity log
-- FK: store_id → restaurants(id), FK: tax_entity_id → tax_entity(id).
-- Append-only (Invariant I5). Only effective_to updated on prior rows.
-- ===========================================================================
CREATE TABLE public.store_tax_entity_history (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id       uuid        NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id  uuid        NOT NULL REFERENCES public.tax_entity(id),
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to   timestamptz,
  reason         text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid        REFERENCES public.users(id)
);

COMMENT ON TABLE  public.store_tax_entity_history IS 'Append-only history of store-to-tax_entity associations. Tracks store sales, restructures, and initial setup. Invariant I5: new associations are new rows; only effective_to is updated on the prior row.';
COMMENT ON COLUMN public.store_tax_entity_history.id             IS 'Primary key.';
COMMENT ON COLUMN public.store_tax_entity_history.store_id       IS 'FK to restaurants.id. Column named store_id (new vocabulary).';
COMMENT ON COLUMN public.store_tax_entity_history.tax_entity_id  IS 'FK to tax_entity. The legal seller associated with this store during this period.';
COMMENT ON COLUMN public.store_tax_entity_history.effective_from IS 'Start of this association.';
COMMENT ON COLUMN public.store_tax_entity_history.effective_to   IS 'End of this association. NULL = currently active.';
COMMENT ON COLUMN public.store_tax_entity_history.reason         IS 'Reason for the association change (e.g. initial_setup, store_sale, restructure).';
COMMENT ON COLUMN public.store_tax_entity_history.created_at     IS 'Row creation timestamp.';
COMMENT ON COLUMN public.store_tax_entity_history.created_by     IS 'FK to users. Admin who recorded the change.';

ALTER TABLE public.store_tax_entity_history ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 9. einvoice_jobs — Per-order WeTax dispatch tracking
-- FK: order_id → orders(id), tax_entity_id → tax_entity(id),
--     einvoice_shop_id → einvoice_shop(id).
-- ref_id UUIDv7 enforced by CHECK (Invariant I8).
-- sid NULLABLE (adaptation point 1).
-- ===========================================================================
CREATE TABLE public.einvoice_jobs (
  id                             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_id                         text        NOT NULL UNIQUE
                                             CHECK (ref_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  order_id                       uuid        NOT NULL REFERENCES public.orders(id),
  tax_entity_id                  uuid        NOT NULL REFERENCES public.tax_entity(id),
  einvoice_shop_id               uuid        NOT NULL REFERENCES public.einvoice_shop(id),
  redinvoice_requested           boolean     NOT NULL DEFAULT false,
  status                         text        NOT NULL DEFAULT 'pending'
                                             CHECK (status IN (
                                               'pending', 'dispatched', 'dispatched_polling_disabled',
                                               'reported', 'issued_by_portal', 'failed_terminal', 'stale'
                                             )),
  send_order_payload             jsonb       NOT NULL,
  request_einvoice_payload       jsonb,
  sid                            text,
  cqt_report_status              text,
  issuance_status                text,
  lookup_url                     text,
  error_classification           text,
  error_message                  text,
  dispatch_attempts              int         NOT NULL DEFAULT 0,
  last_dispatch_at               timestamptz,
  dispatched_at                  timestamptz,
  polling_next_at                timestamptz,
  request_einvoice_retry_count   int         NOT NULL DEFAULT 0,
  request_einvoice_next_retry_at timestamptz,
  created_at                     timestamptz NOT NULL DEFAULT now(),
  updated_at                     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.einvoice_jobs IS 'Per-order WeTax dispatch tracking. Created when order reaches completed status. Two-phase dispatch: sendOrderInfo always; requestEinvoiceInfo only when redinvoice_requested=true. See scope v1.3 Section 6 for state machine.';
COMMENT ON COLUMN public.einvoice_jobs.id                             IS 'Primary key.';
COMMENT ON COLUMN public.einvoice_jobs.ref_id                         IS 'Immutable UUIDv7 job identifier (Invariant I8). Server-generated at creation; CHECK enforces version nibble=7 and variant bits. Used as WeTax order reference across all API calls.';
COMMENT ON COLUMN public.einvoice_jobs.order_id                       IS 'FK to orders. The POS order being reported to WeTax.';
COMMENT ON COLUMN public.einvoice_jobs.tax_entity_id                  IS 'Snapshot of store.tax_entity_id at job creation (Invariant I2). Immutable after creation.';
COMMENT ON COLUMN public.einvoice_jobs.einvoice_shop_id               IS 'Snapshot of active einvoice_shop at job creation. Immutable after creation.';
COMMENT ON COLUMN public.einvoice_jobs.redinvoice_requested           IS 'Customer requested a red invoice at checkout. Triggers requestEinvoiceInfo sub-flow when true.';
COMMENT ON COLUMN public.einvoice_jobs.status                         IS 'Dispatch lifecycle state. dispatched_polling_disabled = sendOrderInfo done but WT06 globally off (system_config).';
COMMENT ON COLUMN public.einvoice_jobs.send_order_payload             IS 'JSONB snapshot of sendOrderInfo payload as transmitted. Preserved for audit and manual reprocessing.';
COMMENT ON COLUMN public.einvoice_jobs.request_einvoice_payload       IS 'JSONB snapshot of requestEinvoiceInfo payload including buyer data. NULL if redinvoice_requested=false.';
COMMENT ON COLUMN public.einvoice_jobs.sid                            IS 'WeTax session identifier. NULLABLE (adaptation point 1): populated from sendOrderInfo response if present, otherwise from WT06 polling.';
COMMENT ON COLUMN public.einvoice_jobs.cqt_report_status              IS 'CQT (tax authority) report status from WT06. NULL until polled.';
COMMENT ON COLUMN public.einvoice_jobs.issuance_status                IS 'Invoice issuance status from WT06. NULL until polled.';
COMMENT ON COLUMN public.einvoice_jobs.lookup_url                     IS 'WeTax portal URL for this invoice from WT06. Used by Open in WeTax Portal button.';
COMMENT ON COLUMN public.einvoice_jobs.error_classification           IS 'Classified error type for failed_terminal/stale jobs. Drives admin dashboard filtering.';
COMMENT ON COLUMN public.einvoice_jobs.error_message                  IS 'Human-readable error from the API or dispatcher.';
COMMENT ON COLUMN public.einvoice_jobs.dispatch_attempts              IS 'Total sendOrderInfo attempt count including retries.';
COMMENT ON COLUMN public.einvoice_jobs.last_dispatch_at               IS 'Most recent sendOrderInfo attempt timestamp.';
COMMENT ON COLUMN public.einvoice_jobs.dispatched_at                  IS 'When job first reached dispatched/dispatched_polling_disabled. Used for FIFO polling order and stale detection (>24h → stale).';
COMMENT ON COLUMN public.einvoice_jobs.polling_next_at                IS 'Scheduled next WT06 poll time. NULL when polling globally disabled.';
COMMENT ON COLUMN public.einvoice_jobs.request_einvoice_retry_count   IS 'Retry count for requestEinvoiceInfo. Drives exponential backoff (adaptation point 3). Reset on manual retry.';
COMMENT ON COLUMN public.einvoice_jobs.request_einvoice_next_retry_at IS 'Scheduled next requestEinvoiceInfo retry. NULL when not in backoff state.';
COMMENT ON COLUMN public.einvoice_jobs.created_at                     IS 'Row creation timestamp.';
COMMENT ON COLUMN public.einvoice_jobs.updated_at                     IS 'Last update timestamp.';

ALTER TABLE public.einvoice_jobs ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 10. einvoice_events — Append-only audit log of einvoice_jobs activity
-- FK: job_id → einvoice_jobs(id) — NULLABLE for system-level events
--     (e.g. polling_activated without a specific job, per scope Appendix B.2).
-- ===========================================================================
CREATE TABLE public.einvoice_events (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id       uuid        REFERENCES public.einvoice_jobs(id),
  event_type   text        NOT NULL,
  description  text,
  retry_count  int,
  raw_request  jsonb,
  raw_response jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.einvoice_events IS 'Append-only audit log of all state changes and API calls for einvoice_jobs. Every dispatcher attempt, poll result, flag flip, and system event writes one row. No updates or deletes.';
COMMENT ON COLUMN public.einvoice_events.id           IS 'Primary key.';
COMMENT ON COLUMN public.einvoice_events.job_id       IS 'FK to einvoice_jobs. NULL for system-level events (e.g. polling_activated) not tied to a specific job.';
COMMENT ON COLUMN public.einvoice_events.event_type   IS 'Event type identifier (e.g. send_order_attempt, poll_result, request_einvoice_attempt, polling_activated, status_transition).';
COMMENT ON COLUMN public.einvoice_events.description  IS 'Human-readable description. Includes error details for failed events.';
COMMENT ON COLUMN public.einvoice_events.retry_count  IS 'Retry count at event time. Relevant for requestEinvoiceInfo backoff events.';
COMMENT ON COLUMN public.einvoice_events.raw_request  IS 'JSONB of API request payload. Redacted of credentials.';
COMMENT ON COLUMN public.einvoice_events.raw_response IS 'JSONB of API response payload. NULL for non-API events.';
COMMENT ON COLUMN public.einvoice_events.created_at   IS 'Event timestamp.';

ALTER TABLE public.einvoice_events ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 11. partner_credential_access_log — Append-only credential access log
-- FK: credential_id → partner_credentials(id).
-- Append-only (Invariant I6). L4 envelope encryption requirement.
-- ===========================================================================
CREATE TABLE public.partner_credential_access_log (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  credential_id        uuid        NOT NULL REFERENCES public.partner_credentials(id),
  accessed_at          timestamptz NOT NULL DEFAULT now(),
  access_reason        text        NOT NULL,
  accessed_by_function text        NOT NULL,
  success              boolean     NOT NULL
);

COMMENT ON TABLE  public.partner_credential_access_log IS 'Append-only log of every decrypt or read of partner_credentials. Required by L4 envelope encryption discipline (Invariant I6). No updates or deletes permitted — enforced by RLS in Step 6.';
COMMENT ON COLUMN public.partner_credential_access_log.id                   IS 'Primary key.';
COMMENT ON COLUMN public.partner_credential_access_log.credential_id        IS 'FK to partner_credentials. The credential that was accessed.';
COMMENT ON COLUMN public.partner_credential_access_log.accessed_at          IS 'Access event timestamp.';
COMMENT ON COLUMN public.partner_credential_access_log.access_reason        IS 'Reason for access (e.g. token_refresh, initial_auth, dispatcher_startup).';
COMMENT ON COLUMN public.partner_credential_access_log.accessed_by_function IS 'Edge function or process identifier (e.g. wetax-dispatcher).';
COMMENT ON COLUMN public.partner_credential_access_log.success              IS 'Whether the access and subsequent operation succeeded.';

ALTER TABLE public.partner_credential_access_log ENABLE ROW LEVEL SECURITY;

COMMIT;
