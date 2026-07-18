\set ON_ERROR_STOP on

BEGIN;

\ir ../../scripts/verify_production_test_entity_guard.sql

ROLLBACK;

SELECT 'PRODUCTION_TEST_ENTITY_GUARD_RUNTIME_TEST_OK' AS result;
