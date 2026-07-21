import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class _OperationalCoverage {
  const _OperationalCoverage({
    required this.source,
    required this.directCalls,
    required this.test,
    required this.markers,
    this.indirectEntrypoints = 0,
  });

  final String source;
  final int directCalls;
  final int indirectEntrypoints;
  final String test;
  final List<String> markers;

  int get totalEntrypoints => directCalls + indirectEntrypoints;
}

const _coverage = <_OperationalCoverage>[
  _OperationalCoverage(
    source: 'lib/core/ui/toast/toast_primitives.dart',
    directCalls: 2,
    test: 'test/toast_confirm_dialog_test.dart',
    markers: ['ToastConfirmDialog.show(', 'ToastConfirmDialog.withContent('],
  ),
  _OperationalCoverage(
    source: 'lib/core/services/table_qr_export_service.dart',
    directCalls: 1,
    test: 'test/table_qr_export_contract_test.dart',
    markers: ['progress dialog fully tears down'],
  ),
  _OperationalCoverage(
    source: 'lib/widgets/pin_dialog.dart',
    directCalls: 1,
    test: 'test/globos_pos_overlay_operational_test.dart',
    markers: ['showPinDialog(context)'],
  ),
  _OperationalCoverage(
    source: 'lib/widgets/order_workspace.dart',
    directCalls: 2,
    test: 'test/waiter_overlay_operational_test.dart',
    markers: ['order_edit_quantity_dialog', 'order_current_ticket_sheet'],
  ),
  _OperationalCoverage(
    source: 'lib/features/waiter/waiter_screen.dart',
    directCalls: 4,
    test: 'test/waiter_overlay_operational_test.dart',
    markers: [
      'waiter_staff_meal_dialog',
      'waiter_guest_count_dialog',
      'waiter_transfer_table_dialog',
      'waiter_cancel_order_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/cashier/cashier_screen.dart',
    directCalls: 10,
    test: 'test/cashier_overlay_operational_test.dart',
    markers: [
      'cashier_cancel_order_dialog',
      'cashier_service_item_dialog',
      'cashier_split_payment_dialog',
      'cashier_discount_dialog',
      'cashier_single_payment_proof_dialog',
      'cashier_single_red_invoice_dialog',
      'cashier_split_payment_proof_dialog',
      'cashier_split_red_invoice_dialog',
      'cashier_payment_method_dialog',
      'cashier_order_items_sheet',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/red_invoice_intake/red_invoice_intake_screen.dart',
    directCalls: 1,
    test: 'test/red_invoice_intake_overlay_operational_test.dart',
    markers: ['red_invoice_intake_edit_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/qr_order/qr_order_screen.dart',
    directCalls: 1,
    test: 'test/qr_order_operational_ui_test.dart',
    markers: ['qr_confirm_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    directCalls: 11,
    test: 'test/inventory_purchase_overlay_operational_test.dart',
    markers: [
      'inventory_recommendation_run_dialog',
      'inventory_recommendation_adjustment_dialog',
      'inventory_receipt_confirmation_dialog',
      'inventory_stock_audit_dialog',
      'inventory_supplier_dialog',
      'inventory_product_dialog',
      'inventory_supplier_item_dialog',
      'inventory_manual_purchase_order_dialog',
      'inventory_repeat_purchase_order_dialog',
      'inventory_recipe_line_dialog',
      'inventory_new_menu_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/super_admin/super_admin_screen.dart',
    directCalls: 5,
    test: 'test/super_admin_overlay_operational_test.dart',
    markers: [
      'super_admin_store_sheet',
      'super_admin_global_template_sheet',
      'super_admin_close_store_dialog',
      'super_admin_purge_store_dialog',
      'super_admin_continue_store_setup_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/photo_ops/photo_ops_screen.dart',
    directCalls: 1,
    test: 'test/remaining_route_operational_state_test.dart',
    markers: ['photo_ops_inventory_adjustment_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/store_setup/widgets/workforce_setup_card.dart',
    directCalls: 2,
    test: 'test/workforce_setup_provisioning_widget_test.dart',
    markers: [
      'store_setup_workforce_config_dialog',
      'store_setup_provision_account_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/kitchen/kitchen_screen.dart',
    directCalls: 1,
    test: 'test/kitchen_overlay_operational_test.dart',
    markers: ['kitchen_failed_print_jobs_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/qc/qc_check_screen.dart',
    directCalls: 2,
    test: 'test/qc_route_overlay_operational_test.dart',
    markers: ['qc_check_network_image_dialog', 'qc_check_picked_image_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/qc/qc_review_screen.dart',
    directCalls: 2,
    test: 'test/qc_route_overlay_operational_test.dart',
    markers: ['qc_review_sheet', 'qc_review_photo_gallery_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/tables_tab.dart',
    directCalls: 5,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: [
      'admin_table_add_dialog',
      'admin_table_edit_dialog',
      'admin_table_qr_rotate_warning_dialog',
      'admin_table_qr_dialog',
      'admin_table_qr_batch_format_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/menu_tab.dart',
    directCalls: 5,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: [
      'admin_menu_add_category_dialog',
      'admin_menu_add_item_dialog',
      'admin_menu_edit_item_dialog',
      'admin_menu_import_preview_dialog',
      'admin_menu_import_validation_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/staff_tab.dart',
    directCalls: 4,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: [
      'admin_staff_attendance_sheet',
      'staff_deactivate_employee_dialog',
      'admin_staff_add_sheet',
      'staff_created_employee_number_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/settings_tab.dart',
    directCalls: 3,
    indirectEntrypoints: 1,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: [
      'settings_payroll_pin_dialog',
      'settings_discount_manager_pin_dialog',
      'settings_printer_destination_dialog',
      'settings_payroll_pin_clear_action',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/qc_tab.dart',
    directCalls: 3,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: [
      'admin_qc_template_sheet',
      'admin_qc_cell_dialog',
      'admin_qc_image_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/inventory_tab.dart',
    directCalls: 4,
    test: 'test/admin_inventory_overlay_operational_test.dart',
    markers: [
      'admin_inventory_ingredient_dialog',
      'admin_inventory_recipe_dialog',
      'admin_inventory_recommendation_run_dialog',
      'admin_inventory_create_purchase_orders_dialog',
    ],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/attendance_tab.dart',
    directCalls: 1,
    test: 'test/admin_core_overlay_operational_test.dart',
    markers: ['attendance_payroll_unlock_dialog'],
  ),
  _OperationalCoverage(
    source: 'lib/features/admin/tabs/einvoice_tab.dart',
    directCalls: 1,
    test: 'test/einvoice_overlay_operational_test.dart',
    markers: ['meinvoice_settings_dialog'],
  ),
];

String _withoutLineComments(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

int _directOverlayCallCount(String source) => RegExp(
  r'\b(?:showDialog|showModalBottomSheet)\b',
).allMatches(_withoutLineComments(source)).length;

void main() {
  test('all 73 dialog and sheet entrypoints map to operational tests', () {
    final discovered = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final count = _directOverlayCallCount(entity.readAsStringSync());
      if (count > 0) discovered[entity.path] = count;
    }

    final expected = <String, int>{
      for (final item in _coverage) item.source: item.directCalls,
    };
    expect(discovered, expected);
    expect(_coverage.fold<int>(0, (sum, item) => sum + item.directCalls), 72);
    expect(
      _coverage.fold<int>(0, (sum, item) => sum + item.totalEntrypoints),
      73,
    );

    final settings = File(
      'lib/features/admin/tabs/settings_tab.dart',
    ).readAsStringSync();
    expect(RegExp(r'\bshowPinDialog\s*\(').allMatches(settings), hasLength(1));

    for (final item in _coverage) {
      expect(
        item.markers,
        hasLength(item.totalEntrypoints),
        reason: '${item.source} needs one operational marker per entrypoint',
      );
      final operationalTest = File(item.test).readAsStringSync();
      for (final marker in item.markers) {
        expect(
          operationalTest,
          contains(marker),
          reason:
              '${item.source} entrypoint $marker is not covered by ${item.test}',
        );
      }
    }
  });
}
