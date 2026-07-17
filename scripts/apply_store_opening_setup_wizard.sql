\set ON_ERROR_STOP on

-- Execute only through scripts/run_pos_production_sql.sh after the dedicated
-- preflight. The runner pins POS production and supplies single-transaction,
-- fail-fast psql semantics.
\ir ../supabase/migrations/20260717090000_store_opening_setup_wizard.sql
