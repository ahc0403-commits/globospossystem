import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production mutations require clean exact-main Git state', () {
    final deploy = File(
      'scripts/deploy_pos_production.sh',
    ).readAsStringSync();

    expect(deploy, contains(r'REQUIRE_CLEAN_GIT="${REQUIRE_CLEAN_GIT:-1}"'));
    expect(deploy, contains('REQUIRE_CLEAN_GIT=0 is allowed only'));
    expect(deploy, contains('production_deploy_path_requested'));
    expect(deploy, contains('enforce_clean_git'));
    expect(deploy, contains('enforce_origin_main_ancestry'));
    expect(
      deploy,
      contains('+refs/heads/main:refs/remotes/origin/main'),
    );
    expect(
      deploy,
      contains(r'$(git -C "$ROOT_DIR" rev-parse HEAD)'),
    );
    expect(deploy, isNot(contains('merge-base --is-ancestor origin/main HEAD')));
    expect(
      deploy,
      contains('Production deployment requires exact HEAD == freshly fetched origin/main'),
    );
    expect(deploy, isNot(contains('ALLOW_GIT_ANCESTRY')));
    expect(deploy, isNot(contains('SKIP_GIT')));
    expect(
      deploy,
      contains('20260713120000_photo_objet_expected_slot_ledger.sql'),
    );
    expect(
      deploy,
      contains('preflight_photo_objet_expected_slot_ledger.sql'),
    );
    expect(
      deploy,
      contains('verify_photo_objet_expected_slot_ledger.sql'),
    );
    expect(
      deploy,
      contains('apply_photo_objet_expected_slot_ledger.sql'),
    );
    expect(
      deploy,
      contains('PHOTO_OBJET_MONITORING_EFFECTIVE_FROM'),
    );
    expect(deploy, contains('PHOTO_POLICY_VALUES=<validated>'));

    final preflight = deploy.substring(
      deploy.indexOf('preflight() {'),
      deploy.indexOf('run_auth_check() {'),
    );
    expect(
      preflight.indexOf('enforce_origin_main_ancestry'),
      lessThan(preflight.indexOf('need_cmd vercel')),
    );

    final mainBody = deploy.substring(deploy.indexOf('main() {'));
    expect(
      mainBody.indexOf('preflight'),
      lessThan(mainBody.indexOf('apply_migration')),
    );
    expect(
      mainBody.indexOf('preflight'),
      lessThan(mainBody.indexOf('deploy_vercel')),
    );
  });

  test('migration history mismatches fail closed around SQL mutation', () {
    final deploy = File(
      'scripts/deploy_pos_production.sh',
    ).readAsStringSync();

    expect(deploy, contains('migration_history_contains_remote_version'));
    expect(deploy, contains('require_migration_history_absent'));
    expect(deploy, contains('require_migration_history_present'));
    expect(deploy, contains('Could not list Supabase migration history'));
    expect(deploy, contains(r'already contains $migration_version'));
    expect(deploy, contains(r'does not contain $migration_version'));
    expect(deploy, isNot(contains('SKIP_REPAIR')));
    expect(deploy, isNot(contains('--skip-repair')));
    expect(deploy, isNot(contains('Could not confirm migration history')));

    final apply = deploy.substring(
      deploy.indexOf('apply_migration() {'),
      deploy.indexOf('rollback_hierarchy() {'),
    );
    expect(
      apply.indexOf('require_migration_history_absent'),
      lessThan(apply.indexOf(r'run_linked_psql_file "$migration_path"')),
    );
    expect(
      apply.indexOf('supabase migration repair'),
      lessThan(apply.lastIndexOf('require_migration_history_present')),
    );

    final rollback = deploy.substring(
      deploy.indexOf('rollback_hierarchy() {'),
      deploy.indexOf('ensure_flutter_env() {'),
    );
    expect(
      rollback.indexOf('require_migration_history_present'),
      lessThan(rollback.indexOf('run_linked_psql_file')),
    );
    expect(
      rollback.indexOf('supabase migration repair'),
      lessThan(rollback.indexOf('require_migration_history_absent')),
    );
  });
}
