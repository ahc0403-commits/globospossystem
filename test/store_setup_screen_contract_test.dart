import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('admin route exposes the six-step wizard and all entry points', () {
    final router = File('lib/core/router/app_router.dart').readAsStringSync();
    final screen = File(
      'lib/features/store_setup/store_setup_screen.dart',
    ).readAsStringSync();
    final settings = File(
      'lib/features/admin/tabs/settings_tab.dart',
    ).readAsStringSync();
    final superAdmin = File(
      'lib/features/super_admin/super_admin_screen.dart',
    ).readAsStringSync();
    final onboarding = File(
      'lib/features/onboarding/onboarding_screen.dart',
    ).readAsStringSync();

    expect(router, contains("path: '/store-setup/:storeId'"));
    expect(router, contains('PermissionUtils.isAdminLike(role)'));
    expect(router, contains('auth.accessibleStores.any'));
    expect(screen, contains("Key('store_setup_six_step_wizard')"));
    for (final step in [
      'storeSetupStepStore',
      'storeSetupStepTables',
      'storeSetupStepPrinters',
      'storeSetupStepRoutes',
      'storeSetupStepAgent',
      'storeSetupStepTests',
    ]) {
      expect(screen, contains(step));
    }
    expect(settings, contains("Key('settings_store_opening_setup')"));
    expect(superAdmin, contains('super_admin_store_setup_'));
    expect(superAdmin, contains("Key('super_admin_continue_store_setup')"));
    expect(onboarding, contains("Key('onboarding_continue_store_setup')"));
  });

  test('wizard uses atomic RPCs and retains queue job IDs', () {
    final service = File(
      'lib/features/store_setup/store_setup_service.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/store_setup/store_setup_provider.dart',
    ).readAsStringSync();
    expect(service, contains("'admin_validate_store_opening_config'"));
    expect(service, contains("'admin_apply_store_opening_config'"));
    expect(service, contains("'admin_get_store_opening_readiness'"));
    expect(service, contains("'admin_enqueue_printer_test_job'"));
    expect(provider, contains('job.jobId.isEmpty'));
    expect(provider, contains('fetchTestJobs'));
    expect(provider, contains('physicallyConfirmed'));
  });

  test('one app-root coordinator owns agent lifetime', () {
    final main = File('lib/main.dart').readAsStringSync();
    final screen = File(
      'lib/features/print_station/print_station_screen.dart',
    ).readAsStringSync();
    final coordinator = File(
      'lib/core/hardware/print_agent_coordinator.dart',
    ).readAsStringSync();
    expect(main, contains('ref.watch(printAgentCoordinatorProvider)'));
    expect(screen, contains('printAgentCoordinatorProvider'));
    expect(screen, isNot(contains('PrintJobAgentService()')));
    expect(coordinator, contains("'print_agent_enabled_v1'"));
    expect(coordinator, contains('await _agent.stopSafely()'));
    expect(coordinator, contains('await _agent.startPollingSafely(_storeId!)'));
  });
}
