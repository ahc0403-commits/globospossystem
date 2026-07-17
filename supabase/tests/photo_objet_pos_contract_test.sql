-- photo_objet_pos_contract_test.sql
-- Guards the POS-side Photo Objet sales contract after legacy 251 migrations.

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(2);

SELECT ok(
  pg_get_viewdef('public.v_photo_objet_daily_summary'::regclass, true)
    ~ 'JOIN (public\.)?restaurants',
  'v_photo_objet_daily_summary joins photo_objet_sales to restaurants'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'photo_objet_sales'
      AND policyname = 'photo_objet_sales_select_scope'
      AND cmd = 'SELECT'
      AND qual ILIKE '%user_accessible_stores%'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'photo_objet_sales'
      AND policyname IN ('po_sales_master', 'po_sales_store')
  ),
  'photo_objet_sales uses POS store-scoped SELECT policy and no legacy office sales policies'
);

SELECT * FROM finish();

ROLLBACK;
