import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('production deploy is gated by required POS pilot Auth accounts', () {
    final deploy = readRepoFile('scripts/deploy_pos_production.sh');
    final checker = readRepoFile('scripts/check_pilot_auth_accounts.sh');
    final authProvider = readRepoFile('lib/features/auth/auth_provider.dart');
    final loginSmoke = readRepoFile('scripts/smoke_pilot_login.sh');
    final runbook = readRepoFile(
      'docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md',
    );
    final provisioningRunbook = readRepoFile(
      'docs/manual_test/pos_pilot_auth_provisioning_runbook.md',
    );
    final accounts = readRepoFile(
      'docs/manual_test/pos_required_pilot_auth_emails.txt',
    );

    expect(deploy, contains('PILOT_AUTH_EMAILS_FILE'));
    expect(deploy, contains('PILOT_LOGIN_SMOKE_SCRIPT'));
    expect(deploy, contains('SKIP_AUTH_CHECK'));
    expect(deploy, contains('SKIP_LOGIN_SMOKE'));
    expect(deploy, contains('run_auth_check'));
    expect(deploy, contains('run_login_smoke'));
    expect(deploy, contains('flutter pub get --enforce-lockfile'));
    expect(
      deploy,
      contains('production checks require locked Flutter dependencies'),
    );
    expect(deploy, contains('Pilot Auth account readiness'));
    expect(deploy, contains('Pilot login smoke'));
    expect(deploy, contains('PILOT_SMOKE_EMAIL'));
    expect(deploy, contains('PILOT_SMOKE_PASSWORD'));
    expect(deploy, contains('Do not report this deploy as login-ready'));
    expect(deploy, contains('SUPABASE_URL is not production'));
    expect(deploy, contains('POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"'));
    expect(deploy, contains('readonly POS_PSQL_ROLE="postgres"'));
    expect(deploy, contains('POS_VERCEL_PROJECT="globospossystem"'));
    expect(deploy, contains('POS_VERCEL_PROJECT_ID='));
    expect(deploy, contains('POS_VERCEL_ORG_ID='));
    expect(deploy, contains('reject_target_overrides'));
    expect(
      deploy,
      contains('is forbidden; POS production targets are hard-pinned'),
    );
    expect(
      deploy,
      contains('supabase db dump --linked --schema public --dry-run'),
    );
    expect(deploy, contains('psql -X --no-psqlrc'));
    expect(deploy, contains('-v ON_ERROR_STOP=1 --single-transaction'));
    expect(deploy, contains('--command "SET ROLE \$POS_PSQL_ROLE;"'));
    expect(deploy, contains('POS_PSQL_ROLE_ACTIVATION_FAILED'));
    expect(deploy, contains('pg_catalog.pg_has_role'));
    expect(deploy, contains("session_user !~ '^cli_login_'"));
    expect(deploy, contains('PGSSLMODE=require'));
    expect(deploy, contains('cli_login_'));
    expect(deploy, contains('PASS: %s'));
    expect(deploy, contains('verification_complete=1'));
    expect(deploy, contains('has no explicit verification phase'));
    expect(
      deploy,
      contains('CONFIRM_HIERARCHY_ROLLBACK=ROLLBACK_HIERARCHY_20260711090000'),
    );
    expect(deploy, isNot(contains('supabase db query')));
    expect(deploy, isNot(contains('supabase db query --db-url')));
    expect(deploy, isNot(contains('ALLOW_PROJECT_REF_MISMATCH:-')));
    final psqlRunner = deploy.substring(
      deploy.indexOf('run_linked_psql_file() {'),
      deploy.indexOf('migration_history_contains_remote_version() {'),
    );
    expect(
      psqlRunner.indexOf(r'--command "SET ROLE $POS_PSQL_ROLE;"'),
      lessThan(psqlRunner.indexOf(r'--command "$role_check_sql"')),
    );
    expect(
      psqlRunner.indexOf(r'--command "$role_check_sql"'),
      lessThan(psqlRunner.indexOf(r'--file "$file"')),
    );
    expect(
      deploy,
      contains('preflight_legal_entity_brand_store_hierarchy.sql'),
    );
    expect(deploy, contains('verify_legal_entity_brand_store_hierarchy.sql'));
    expect(
      deploy.indexOf('run_auth_check'),
      lessThan(deploy.indexOf('run_checks')),
    );
    final checks = deploy.substring(
      deploy.indexOf('run_checks() {'),
      deploy.indexOf('parse_linked_pg_exports() {'),
    );
    expect(
      checks.indexOf('flutter pub get --enforce-lockfile'),
      lessThan(checks.indexOf('dart analyze')),
    );
    expect(
      checks.indexOf('dart analyze'),
      lessThan(checks.indexOf('flutter test')),
    );
    final mainBody = deploy.substring(deploy.indexOf('main() {'));
    expect(
      mainBody.indexOf('load_env'),
      lessThan(mainBody.indexOf('run_auth_check')),
    );
    expect(
      mainBody.indexOf('run_checks'),
      lessThan(mainBody.indexOf('apply_migration')),
    );
    expect(
      mainBody.indexOf('deploy_vercel'),
      lessThan(mainBody.indexOf('run_login_smoke')),
    );

    expect(checker, contains('auth.users'));
    expect(checker, contains('public.users'));
    expect(checker, contains('pu.auth_id = au.id'));
    expect(checker, isNot(contains('pu.id = au.id')));
    expect(checker, contains('MISSING_AUTH'));
    expect(checker, contains('MISSING_POS_PROFILE'));
    expect(checker, contains('UNCONFIRMED_AUTH'));
    expect(checker, contains('INACTIVE_POS_PROFILE'));
    expect(checker, contains('UNKNOWN_ROLE'));
    expect(checker, contains('MISSING_STORE_SCOPE'));
    expect(checker, contains('INVALID_STORE_SCOPE'));
    expect(checker, contains('raw_app_meta_data'));
    expect(checker, contains('jsonb_array_elements_text'));
    expect(checker, contains('accessible_store_ids'));
    expect(checker, contains('public.restaurants'));
    expect(checker, contains('ROOT_CAUSE: Required POS pilot identity state'));
    expect(checker, contains('NEXT_ACTION MISSING_AUTH'));
    expect(checker, contains('NEXT_ACTION UNCONFIRMED_AUTH'));
    expect(checker, contains('NEXT_ACTION MISSING_POS_PROFILE'));
    expect(checker, contains('NEXT_ACTION INACTIVE_POS_PROFILE'));
    expect(checker, contains('NEXT_ACTION UNKNOWN_ROLE'));
    expect(checker, contains('NEXT_ACTION MISSING_STORE_SCOPE'));
    expect(checker, contains('NEXT_ACTION INVALID_STORE_SCOPE'));
    expect(checker, contains('APP_PROFILE_LOOKUP'));
    expect(checker, contains('pos_pilot_auth_provisioning_runbook.md'));
    expect(checker, contains('reads, prints, creates, or resets passwords'));
    expect(checker, contains('resets passwords'));

    expect(loginSmoke, contains('PILOT_SMOKE_EMAIL'));
    expect(loginSmoke, contains('PILOT_SMOKE_PASSWORD'));
    expect(loginSmoke, contains('/auth/v1/token?grant_type=password'));
    expect(loginSmoke, contains('/rest/v1/users'));
    expect(loginSmoke, contains('auth_id=eq.'));
    expect(loginSmoke, contains('never prints, creates, or resets passwords'));
    expect(loginSmoke, contains('SUPABASE_URL is not production'));
    expect(loginSmoke, contains('Pilot login smoke failed'));
    expect(loginSmoke, contains('Pilot login smoke passed'));
    expect(loginSmoke, contains(r'rm -f "${login_response_file:-}"'));

    expect(runbook, contains('auth.users.email -> auth.users.id'));
    expect(runbook, contains('public.users.auth_id'));
    expect(runbook, contains('public.users.id ='));
    expect(runbook, contains('MISSING_AUTH'));
    expect(runbook, contains('INACTIVE_POS_PROFILE'));
    expect(runbook, contains('UNKNOWN_ROLE'));
    expect(runbook, contains('MISSING_STORE_SCOPE'));
    expect(runbook, contains('INVALID_STORE_SCOPE'));
    expect(runbook, contains('app_metadata.accessible_store_ids'));
    expect(runbook, contains('A frontend deploy cannot create'));
    expect(runbook, contains('manual live URL check'));
    expect(runbook, contains('pos_pilot_auth_provisioning_runbook.md'));

    expect(provisioningRunbook, contains('auth.users.email -> auth.users.id'));
    expect(provisioningRunbook, contains('public.users.auth_id'));
    expect(provisioningRunbook, contains('For `MISSING_AUTH`'));
    expect(provisioningRunbook, contains('Do not store passwords'));
    expect(provisioningRunbook, contains('Deployment automation must verify'));

    expect(accounts, contains('waiter@globos.test'));
    expect(accounts, contains('kitchen@globos.test'));
    expect(accounts, contains('cashier@globos.test'));
    expect(accounts, contains('admin@globos.test'));
    expect(accounts, contains('superadmin@globos.test'));
    expect(accounts, contains('pos.validation.codex@globos.test'));
    expect(accounts, isNot(contains('dung.cashier01@globos.test')));
    expect(accounts, isNot(contains('Dung@POS')));
    expect(accounts, isNot(contains('1234')));
    expect(accounts, isNot(contains('!')));

    expect(authProvider, contains(".eq('auth_id', user.id)"));
  });
}
