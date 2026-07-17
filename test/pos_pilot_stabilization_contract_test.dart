import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('POS pilot stabilization fixes are present by failed flow', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');
    final kitchen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final kitchenProvider = readRepoFile(
      'lib/features/kitchen/kitchen_provider.dart',
    );
    final staffTab = readRepoFile('lib/features/admin/tabs/staff_tab.dart');
    final staffProvider = readRepoFile(
      'lib/features/admin/providers/staff_provider.dart',
    );
    final settings = readRepoFile('lib/features/admin/tabs/settings_tab.dart');
    final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final reportProvider = readRepoFile(
      'lib/features/report/report_provider.dart',
    );
    final inventoryPurchase = readRepoFile(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final en = readRepoFile('lib/l10n/app_localizations_en.dart');
    final ko = readRepoFile('lib/l10n/app_localizations_ko.dart');
    final vi = readRepoFile('lib/l10n/app_localizations_vi.dart');

    expect(
      waiter,
      contains(
        'guestCount = await _showGuestCountDialog(maxGuests: table.seatCount);',
      ),
    );
    expect(waiter, contains('waiterGuestCountOverSeatLimit(maxGuests)'));
    expect(waiter, contains('refreshOrderPreviews(storeId)'));
    expect(waiter, contains('clearSession()'));
    expect(workspace, contains("'order_current_ticket_reconfirm_header'"));
    expect(workspace, contains("'order_current_ticket_reconfirm_hint'"));
    expect(workspace, contains("'order_current_ticket_detail_action'"));
    expect(workspace, contains("'order_current_ticket_detail_action_compact'"));
    expect(workspace, contains("'order_cancel_order_direct_action'"));
    expect(workspace, contains("'order_cancel_order_direct_action_compact'"));
    expect(workspace, contains("'order_current_ticket_open_detail_button'"));
    expect(workspace, contains("'order_waiter_ready_handoff_notice'"));
    expect(workspace, contains('class _CurrentTicketDetailSheet'));
    expect(workspace, contains('orderWorkspaceItemLockedAfterKitchen'));
    expect(workspace, contains("'menu thử phục vụ'"));
    expect(workspace, contains("'테스트 보리차'"));
    expect(workspace, contains("'테스트 만두'"));
    expect(workspace, contains("'테스트 냉면'"));
    expect(workspace, contains("'테스트 치킨'"));
    expect(workspace, contains('order_sent_item_reconfirm_'));
    expect(workspace, contains('_localizedMenuDataLabel'));
    expect(workspace, contains("'vi' => 'Món ăn'"));

    expect(kitchen, contains("Key('kitchen_state_flow_legend')"));
    expect(kitchen, contains("'kitchen_ticket_search_toolbar'"));
    expect(kitchen, contains("'kitchen_ticket_search_field'"));
    expect(kitchen, contains('kitchenTicketCode'));
    expect(kitchen, contains('kitchenSupplementalItem'));
    expect(kitchen, contains("'kitchen_ticket_supplemental_badge_"));
    expect(kitchen, contains('_localizedKitchenItemLabel'));
    expect(kitchen, contains("'테스트 보리차'"));
    expect(kitchen, contains("'테스트 만두'"));
    expect(kitchen, contains('_filterKitchenOrders'));
    expect(kitchenProvider, contains('isSupplemental'));
    expect(kitchenProvider, contains('firstItemCreatedAt'));
    expect(kitchen, contains('const int _kitchenStaleDisplayHours = 24;'));
    expect(kitchen, contains('Duration _kitchenDisplayElapsed'));
    expect(kitchen, contains("return context.l10n.kitchenReadyHandoff;"));
    expect(waiter, contains('refreshOrderPreviews(storeId)'));

    expect(staffTab, contains("Key('staff_create_validation_message')"));
    expect(staffTab, contains("Key('staff_created_employee_number_dialog')"));
    expect(staffTab, contains('staffEmployeeNumberGeneratedHint'));
    expect(staffTab, contains('staffEmployeeNumberReadOnly'));
    expect(staffTab, contains('staffEmployeeNameRequired'));
    expect(staffProvider, contains('_cleanException'));
    expect(staffProvider, contains('StaffMember.fromJson(created)'));

    expect(settings, contains('_payrollPinPilotSaveError'));
    expect(settings, contains('restaurant_settings restaurant_id uniqueness'));
    expect(settings, contains('set_payroll_pin'));

    expect(reportProvider, contains('required this.openOrders'));
    expect(reportProvider, contains('final int openOrders;'));
    expect(reports, contains('summary.openOrders'));
    expect(en, contains("String get reportsTotalSales => 'Paid sales';"));
    expect(ko, contains("String get reportsTotalSales => '결제완료 매출';"));
    expect(
      vi,
      contains("String get reportsTotalSales => 'Doanh thu đã thanh toán';"),
    );
    expect(en, contains('Guest count cannot exceed'));
    expect(vi, contains('Số khách không được vượt quá'));
    expect(ko, contains('손님 수는'));
    expect(en, isNot(contains(r'Table T$tableNumber order will be cancelled')));
    expect(vi, isNot(contains(r'bàn T$tableNumber')));
    expect(ko, isNot(contains(r'T$tableNumber 테이블')));
    expect(vi, contains("String get orderWorkspaceCurrentCheckDetails"));
    expect(vi, contains("String get kitchenTicketSearchLabel"));

    expect(
      inventoryPurchase,
      contains("'inventory_receiving_office_gate_notice'"),
    );
    expect(inventoryPurchase, contains('_receivingPilotBlockerMessage'));
    expect(
      inventoryPurchase,
      contains("'inventory_product_category_quick_pick'"),
    );
    expect(
      inventoryPurchase,
      contains("'inventory_product_validation_message'"),
    );
    expect(
      inventoryPurchase,
      contains('Shelf life days is required and must be zero or higher.'),
    );
  });
}
