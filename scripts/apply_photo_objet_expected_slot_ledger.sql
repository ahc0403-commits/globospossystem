\set ON_ERROR_STOP on

-- psql resolves \ir relative to this file. The production runner wraps this
-- entire include chain in one transaction, so schema, approved policies, and
-- first-day expectations either all commit or all roll back.
\ir ../supabase/migrations/20260713120000_photo_objet_expected_slot_ledger.sql
\ir configure_photo_objet_monitoring_policies.sql
