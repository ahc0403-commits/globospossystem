import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class _RouteStateCoverage {
  const _RouteStateCoverage({
    required this.location,
    required this.operationalTest,
    required this.stateMarkers,
  });

  final String location;
  final String operationalTest;
  final List<String> stateMarkers;
}

const _routeStateCoverage = <_RouteStateCoverage>[
  _RouteStateCoverage(
    location: '/qr/fixture-token',
    operationalTest: 'test/qr_order_operational_ui_test.dart',
    stateMarkers: [
      'qr_state_loading',
      'qr_state_empty',
      'qr_state_offline_retry',
      'qr_state_success',
      'qr_state_rate_limit',
    ],
  ),
  _RouteStateCoverage(
    location: '/login',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: ['auth_error_text', 'login_submit_button'],
  ),
  _RouteStateCoverage(
    location: '/privacy-consent',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'privacy_consent_error_text',
      'privacy_consent_checkbox',
      'privacyConsentAcceptButtonKey',
    ],
  ),
  _RouteStateCoverage(
    location: '/onboarding',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: ['OnboardingState(', 'step: 1', 'step: 2'],
  ),
  _RouteStateCoverage(
    location: '/waiter',
    operationalTest: 'test/waiter_overlay_operational_test.dart',
    stateMarkers: [
      'waiter-empty-detail',
      'waiter_guest_count_dialog',
      'waiter_cancel_order_dialog',
      'waiter_transfer_table_dialog',
    ],
  ),
  _RouteStateCoverage(
    location: '/kitchen',
    operationalTest: 'test/kitchen_overlay_operational_test.dart',
    stateMarkers: ['Printer offline', 'kitchen_failed_print_jobs_dialog'],
  ),
  _RouteStateCoverage(
    location: '/print-station',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'isSupportedOverride: false',
      'queue offline',
      'PrinterDestinationErrorCodes.loadFailed',
    ],
  ),
  _RouteStateCoverage(
    location: '/cashier',
    operationalTest: 'test/cashier_overlay_operational_test.dart',
    stateMarkers: [
      'paymentSuccess: true',
      'cashier_discount_dialog',
      'cashier_split_payment_dialog',
      'cashier_cancel_order_dialog',
    ],
  ),
  _RouteStateCoverage(
    location: '/attendance-kiosk',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'Completer<bool>()',
      'Stream.value(false)',
      'attendance_employee_clock_in',
    ],
  ),
  _RouteStateCoverage(
    location: '/qc-check',
    operationalTest: 'test/qc_route_overlay_operational_test.dart',
    stateMarkers: [
      'qc_check_network_image_dialog',
      'qc_check_picked_image_dialog',
    ],
  ),
  _RouteStateCoverage(
    location: '/qc-review',
    operationalTest: 'test/qc_route_overlay_operational_test.dart',
    stateMarkers: ['qc_review_sheet', 'qc_review_photo_gallery_dialog'],
  ),
  _RouteStateCoverage(
    location: '/photo-ops',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'PhotoOpsState(isLoading: true)',
      'Photo queue unavailable',
      'PhotoOpsDashboardData(',
    ],
  ),
  _RouteStateCoverage(
    location: '/payments/payment-fixture',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'AppLoadingView',
      'AppErrorState',
      'AppEmptyState',
      '48.000 VND',
    ],
  ),
  _RouteStateCoverage(
    location: '/super-admin',
    operationalTest: 'test/super_admin_overlay_operational_test.dart',
    stateMarkers: [
      'SuperAdminState(',
      'super_admin_store_sheet',
      'super_admin_close_store_dialog',
    ],
  ),
  _RouteStateCoverage(
    location: '/restaurant-sales-export',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'Completer<RestaurantSalesExport>',
      'RESTAURANT_EXPORT_NOT_READY',
      'restaurant_sales_export_status',
    ],
  ),
  _RouteStateCoverage(
    location: '/store-setup/7f6c9d22-6d84-4c7f-b923-79c81c4015d1',
    operationalTest: 'test/remaining_route_operational_state_test.dart',
    stateMarkers: [
      'StoreSetupState(draft: _storeSetupDraft())',
      'StoreSetupPhase.blocked',
      'StoreSetupPhase.validating',
      'store_setup_six_step_wizard',
    ],
  ),
  _RouteStateCoverage(
    location: '/admin',
    operationalTest: 'test/admin_core_overlay_operational_test.dart',
    stateMarkers: [
      'all five table dialog entrypoints',
      'all five menu dialog entrypoints',
      'all four staff sheet and dialog entrypoints',
      'all four Settings dialog entrypoints',
    ],
  ),
  _RouteStateCoverage(
    location: '/admin/store-fixture',
    operationalTest:
        'test/globos_pos_operational_ui_coverage_contract_test.dart',
    stateMarkers: [
      'all ten Admin tabs render localized selected operational workspaces',
      'selectedNav',
      'Tristate.isTrue',
    ],
  ),
];

void main() {
  test('all 18 routes map to applicable operational state tests', () {
    expect(_routeStateCoverage, hasLength(18));
    expect(
      _routeStateCoverage.map((coverage) => coverage.location).toSet(),
      hasLength(18),
    );

    final routedSurfaceTest = File(
      'test/globos_pos_routed_surface_operational_test.dart',
    ).readAsStringSync();
    for (final coverage in _routeStateCoverage) {
      expect(
        routedSurfaceTest,
        contains("location: '${coverage.location}'"),
        reason: '${coverage.location} is missing from the routed surface test',
      );
      final operationalTest = File(coverage.operationalTest).readAsStringSync();
      for (final marker in coverage.stateMarkers) {
        expect(
          operationalTest,
          contains(marker),
          reason:
              '${coverage.location} state $marker is not covered by '
              '${coverage.operationalTest}',
        );
      }
    }
  });
}
