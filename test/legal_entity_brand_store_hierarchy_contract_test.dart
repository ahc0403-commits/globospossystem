import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql';
const runbookPath = 'docs/legal_entity_brand_store_hierarchy.md';
const preflightPath =
    'scripts/preflight_legal_entity_brand_store_hierarchy.sql';
const verifyPath = 'scripts/verify_legal_entity_brand_store_hierarchy.sql';
const rollbackPath = 'scripts/rollback_legal_entity_brand_store_hierarchy.sql';
const rpcSmokePath =
    'supabase/tests/legal_entity_brand_store_hierarchy_rpc_test.sql';
const deploySmokePath = 'test/pos_deploy_psql_runner_test.sh';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('legal entities map many-to-many to brands and validate stores', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.tax_entity_brands'),
    );
    expect(sql, contains("FROM pg_policies"));
    expect(sql, contains("policyname = 'tax_entity_brands_read_scope'"));
    expect(sql, contains('CREATE POLICY tax_entity_brands_read_scope'));
    expect(sql, contains('PRIMARY KEY (tax_entity_id, brand_id)'));
    expect(sql, contains('INSERT INTO public.tax_entity_brands'));
    expect(sql, contains('SELECT DISTINCT r.tax_entity_id, r.brand_id'));
    expect(
      sql,
      contains('COALESCE(b.suggested_tax_entity_id, placeholder.id)'),
    );
    expect(sql, contains('restaurants_tax_entity_brand_fk'));
    expect(sql, contains('FOREIGN KEY (tax_entity_id, brand_id)'));
    expect(sql, contains('REFERENCES public.tax_entity_brands'));
    expect(
      sql,
      contains('VALIDATE CONSTRAINT restaurants_tax_entity_brand_fk'),
    );
  });

  test(
    'owner type is authoritative and Office eligibility is internal-only',
    () {
      final sql = readRepoFile(migrationPath);

      expect(sql, contains('sync_restaurant_store_type_from_tax_entity'));
      expect(sql, contains("WHEN 'internal' THEN 'direct'"));
      expect(sql, contains("WHEN 'external' THEN 'external'"));
      expect(sql, contains('sync_stores_after_tax_entity_owner_change'));
      expect(
        sql,
        contains('CREATE OR REPLACE VIEW public.v_office_eligible_stores'),
      );
      expect(sql, contains("te.owner_type = 'internal'"));
      expect(sql, contains('link_office_pending_store_for_pos_store_v2'));
      expect(sql, contains('OFFICE_LINK_INTERNAL_ENTITY_REQUIRED'));
      expect(sql, contains("IF v_owner_type = 'internal' THEN"));
    },
  );

  test('v2 hierarchy mutations are guarded, audited, and granted narrowly', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('admin_upsert_tax_entity_v2'));
    expect(sql, contains('admin_set_tax_entity_brand_link_v2'));
    expect(sql, contains('admin_create_restaurant_v2'));
    expect(sql, contains('admin_update_restaurant_v2'));
    expect(sql, contains("v_actor.role <> 'super_admin'"));
    expect(sql, contains('INSERT INTO public.audit_logs'));
    expect(sql, contains('REVOKE ALL ON FUNCTION'));
    expect(sql, contains('GRANT EXECUTE ON FUNCTION'));
    expect(sql, contains('TO authenticated'));
  });

  test('v2 store RPCs maintain append-only legal-entity history', () {
    final sql = readRepoFile(migrationPath);
    final createStart = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_create_restaurant_v2(',
    );
    final updateStart = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_update_restaurant_v2(',
      createStart,
    );
    final createRpc = sql.substring(createStart, updateStart);
    final updateEnd = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_create_restaurant(',
      updateStart,
    );
    final updateRpc = sql.substring(updateStart, updateEnd);

    expect(createRpc, contains('INSERT INTO public.store_tax_entity_history'));
    expect(createRpc, contains('v_changed_at'));
    expect(createRpc, contains('v_actor.id'));
    expect(createRpc, contains('source=none;destination=%s'));
    expect(updateRpc, contains('IS DISTINCT FROM v_updated.tax_entity_id'));
    expect(updateRpc, contains('SET effective_to = v_changed_at'));
    expect(updateRpc, contains('AND effective_to IS NULL'));
    expect(updateRpc, contains('INSERT INTO public.store_tax_entity_history'));
    expect(updateRpc, contains('source=%s;destination=%s'));
    expect(
      updateRpc,
      isNot(contains('DELETE FROM public.store_tax_entity_history')),
    );
  });

  test(
    'executable RPC smoke covers create, no-op, and reassignment history',
    () {
      final smoke = readRepoFile(rpcSmokePath);

      expect(smoke, contains(r'\set ON_ERROR_STOP on'));
      expect(smoke, contains('BEGIN;'));
      expect(smoke, contains('ROLLBACK;'));
      expect(smoke, contains('public.admin_create_restaurant_v2('));
      expect(smoke, contains('public.admin_update_restaurant_v2('));
      expect(smoke, contains('same-entity update is a history no-op'));
      expect(smoke, contains('count(*) = 1'));
      expect(smoke, contains('effective_to = v_active_history.effective_from'));
      expect(smoke, contains('source=%s;destination=%s'));
      expect(smoke, contains('created_by = v_actor.id'));
    },
  );

  test('Office bridge is optional and still validates the full tuple', () {
    final sql = readRepoFile(migrationPath);
    final v2Start = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.link_office_pending_store_for_pos_store_v2(',
    );
    final v2End = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_upsert_tax_entity_v2(',
      v2Start,
    );
    final v2 = sql.substring(v2Start, v2End);

    expect(v2, contains("v_owner_type <> 'internal'"));
    expect(v2, contains('teb.brand_id = p_brand_id'));
    expect(v2, contains('r.id = p_pos_store_id'));
    expect(v2, contains('r.tax_entity_id = p_tax_entity_id'));
    expect(v2, contains('r.brand_id = p_brand_id'));
    expect(v2, contains('OFFICE_LINK_STORE_HIERARCHY_MISMATCH'));
    expect(v2, contains("to_regclass('ops.stores') IS NULL"));
    expect(v2, contains("to_regprocedure("));
    expect(v2, contains('RETURN NULL;'));
    expect(v2, contains('EXECUTE'));
    expect(sql, isNot(contains('status = \'inactive\'::core.account_status')));
    expect(sql, isNot(contains('FROM ops.stores office_store')));
  });

  test('AKJ Photo Objet backfill is deterministic and invoice-safe', () {
    final sql = readRepoFile(migrationPath);
    final docs = readRepoFile(runbookPath);

    expect(sql, contains('a6bda671-4179-5a29-a798-76357b42b497'));
    expect(sql, contains('PENDING_AKJ_TAX_PROFILE'));
    expect(sql, contains("onboarding_status = 'pending_tax_profile'"));
    expect(sql, contains('77000000-0000-0000-0000-000000000001'));
    expect(sql, contains("tax_code = 'PLACEHOLDER_DEV_000'"));
    expect(sql, contains('guard_pending_tax_entity_meinvoice_activation'));
    expect(sql, contains('TAX_ENTITY_TAX_PROFILE_NOT_READY'));
    expect(sql, contains('hierarchy_20260711090000_photo_backup'));
    expect(sql, contains('hierarchy_20260711090000_history_backup'));
    expect(sql, contains('hierarchy_20260711090000_backup_state'));
    expect(sql, contains('snapshot_completed_at'));
    expect(sql, contains('IF NOT EXISTS ('));
    expect(sql, contains('WHERE singleton = true'));
    expect(sql, contains('public.store_tax_entity_history'));
    expect(sql, contains('photo_objet_source;actor=migration;destination='));
    expect(sql, contains('photo_objet_destination;actor=migration;source='));
    expect(docs, contains('실제 세금번호를 입력하기 전에는 발행할 수 없다'));
    expect(docs, contains('같은 브랜드를 여러 법인에 연결'));
    expect(docs, isNot(contains('0318453298')));
  });

  test('legacy store RPCs remain as compatibility wrappers', () {
    final sql = readRepoFile(migrationPath);
    final legacyUpdateStart = sql.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_update_restaurant(',
    );
    final legacyUpdateEnd = sql.indexOf(
      'REVOKE ALL ON FUNCTION public.link_office_pending_store_for_pos_store_v2',
      legacyUpdateStart,
    );
    final legacyUpdate = sql.substring(legacyUpdateStart, legacyUpdateEnd);

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.admin_create_restaurant('),
    );
    expect(sql, contains('public.admin_create_restaurant_v2('));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.admin_update_restaurant('),
    );
    expect(
      legacyUpdate,
      contains('public.require_admin_actor_for_restaurant(v_existing.id)'),
    );
    expect(
      legacyUpdate,
      contains("RAISE EXCEPTION 'RESTAURANT_TAX_ENTITY_BRAND_INVALID'"),
    );
    expect(legacyUpdate, isNot(contains('public.admin_update_restaurant_v2(')));
    expect(sql, contains("v_actor.role <> 'super_admin'"));
    expect(sql, contains('p_store_type is retained for API compatibility'));
    expect(sql, isNot(contains('DROP TABLE public.restaurants')));
    expect(sql, isNot(contains('ALTER TABLE public.restaurants RENAME')));
  });

  test(
    'production SQL has separate preflight, verify, and guarded rollback',
    () {
      final preflight = readRepoFile(preflightPath);
      final verify = readRepoFile(verifyPath);
      final rollback = readRepoFile(rollbackPath);

      expect(preflight, contains('HIERARCHY_PREFLIGHT_PHOTO_CANDIDATE_COUNT'));
      expect(
        preflight,
        contains('HIERARCHY_PREFLIGHT_HISTORY_SCHEMA_MISMATCH'),
      );
      expect(preflight, isNot(contains('UPDATE public.restaurants')));
      expect(
        verify,
        contains('HIERARCHY_VERIFY_INVALID_ENTITY_BRAND_STORE_TUPLE'),
      );
      expect(verify, contains('HIERARCHY_VERIFY_PHOTO_HISTORY_MISMATCH'));
      expect(verify, contains('HIERARCHY_VERIFY_BACKUP_SNAPSHOT_INCOMPLETE'));
      expect(
        verify,
        contains('HIERARCHY_VERIFY_BACKUP_CONTAINS_GENERATED_HISTORY'),
      );
      expect(verify, contains('HIERARCHY_VERIFY_OFFICE_ELIGIBILITY_MISMATCH'));
      expect(verify, isNot(contains('UPDATE public.restaurants')));
      expect(rollback, contains('DESTRUCTIVE ROLLBACK'));
      expect(rollback, contains('HIERARCHY_ROLLBACK_CAPTURE_MISSING'));
      expect(
        rollback,
        contains('HIERARCHY_ROLLBACK_REFUSED_PHOTO_MAPPING_CHANGED'),
      );
      expect(rollback, contains('hierarchy_20260711090000_object_backup'));
      expect(rollback, contains('EXECUTE v_definition'));
      expect(rollback, contains('HIERARCHY_ROLLBACK_RESTORE_MAPPING_MISMATCH'));
      expect(rollback, contains('HIERARCHY_ROLLBACK_RESTORE_HISTORY_MISMATCH'));
      expect(
        rollback,
        contains('HIERARCHY_ROLLBACK_GENERATED_HISTORY_REMAINS'),
      );
      expect(rollback, contains('EXCEPT'));
    },
  );

  test('verification fails closed when the object backup is missing', () {
    final verify = readRepoFile(verifyPath);

    expect(
      verify,
      contains("to_regclass('public.hierarchy_20260711090000_object_backup')"),
    );
    expect(verify, contains('HIERARCHY_VERIFY_MIGRATION_ARTIFACT_MISSING'));
  });

  test('verification rejects a backed-up PHOTO store missing live state', () {
    final verify = readRepoFile(verifyPath);

    expect(
      verify,
      contains('LEFT JOIN public.restaurants r ON r.id = b.store_id'),
    );
    expect(verify, contains('WHERE r.id IS NULL'));
    expect(verify, contains('HIERARCHY_VERIFY_PHOTO_STORE_MISSING'));
  });

  test(
    'deployment smoke executes fail-fast and restoration behavior locally',
    () {
      final smoke = readRepoFile(deploySmokePath);

      expect(smoke, contains('postgres:15'));
      expect(smoke, contains('db dump --linked --schema public --dry-run'));
      expect(smoke, contains('ON_ERROR_STOP=1 --single-transaction --file'));
      expect(smoke, contains('runner_mid_file_rollback'));
      expect(smoke, contains('FAKE_PGHOST='));
      expect(smoke, contains('temporary-secret-must-never-appear'));
      expect(smoke, contains('HIERARCHY_VERIFY_MIGRATION_ARTIFACT_MISSING'));
      expect(smoke, contains('hierarchy replay smoke'));
      expect(smoke, contains('exact rollback assertion'));
    },
  );
}
