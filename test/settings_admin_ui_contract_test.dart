import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('promotion and QR takeout remain independent settings entrypoints', () {
    final promotionSource = readRepoFile(
      'lib/features/settings/promotion_settings_card.dart',
    );
    final qrTakeoutSource = readRepoFile(
      'lib/features/settings/qr_takeout_settings_card.dart',
    );
    final settingsSource = readRepoFile(
      'lib/features/admin/tabs/settings_tab.dart',
    );
    final promotionService = readRepoFile(
      'lib/features/settings/promotion_service.dart',
    );
    final qrTakeoutService = readRepoFile(
      'lib/features/settings/qr_takeout_service.dart',
    );
    final koreanMessages = readRepoFile('lib/l10n/app_ko.arb');

    expect(promotionSource, contains('promotion_settings_dialog'));
    expect(promotionSource, contains('settings_promotion_add_action'));
    expect(promotionSource, contains('settingsPromotionPercent'));
    expect(promotionSource, contains('promotionScopeSelectedItems'));
    expect(promotionSource, contains('promotion_menu_'));
    expect(promotionSource, contains('settingsPromotionMenuRequired'));
    expect(promotionSource, isNot(contains('settings_qr_takeout_toggle')));
    expect(qrTakeoutSource, contains('settings_qr_takeout_section'));
    expect(qrTakeoutSource, contains('settings_qr_takeout_toggle'));
    expect(qrTakeoutSource, contains('settings_qr_takeout_schedule_resume'));
    expect(qrTakeoutSource, contains('settings_qr_takeout_resume_dialog'));
    expect(qrTakeoutSource, contains('settingsQrTakeoutResumeAt'));
    expect(settingsSource, contains('PromotionSettingsCard(storeId: storeId)'));
    expect(settingsSource, contains('QrTakeoutSettingsCard(storeId: storeId)'));
    expect(promotionService, isNot(contains('qr_takeout')));
    expect(qrTakeoutService, contains('get_qr_takeout_availability'));
    expect(qrTakeoutService, contains('set_qr_takeout_availability'));
    expect(koreanMessages, contains('고객 QR 메뉴에서 포장 주문 선택을 표시하거나 숨깁니다.'));
    expect(koreanMessages, isNot(contains('프로모션 운영 중 고객 QR 메뉴')));
  });

  test('settings admin surface stays configuration-primary', () {
    final source = readRepoFile('lib/features/admin/tabs/settings_tab.dart');

    expect(source, contains('_buildSettingsConfigurationHeader'));
    expect(source, contains("Key('settings_configuration_header')"));
    expect(source, contains("Key('settings_configuration_queue')"));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("Key('settings_audit_trace_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, contains('settingsProvider'));
    expect(source, contains('printerProvider'));
    expect(source, contains('pinService'));
    expect(source, contains('AdminAuditTracePanel('));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
  });

  test('settings compact stack does not nest panel vertical scroll', () {
    final source = readRepoFile('lib/features/admin/tabs/settings_tab.dart');

    expect(source, contains('PosLayoutSpec.from(context, viewport)'));
    expect(source, contains('layout.prefersSingleColumn'));
    expect(source, contains('horizontal: layout.prefersSingleColumn'));
    expect(source, contains('ToastResponsiveScrollBody('));
    expect(source, contains('settingsPanel(scrollable: false)'));
    expect(source, contains('settingsPanel(scrollable: true)'));
    expect(source, contains('required bool scrollable'));
    expect(source, contains('Widget _settingsPanelBody'));
    expect(source, contains('if (!scrollable)'));
    expect(source, contains('return SingleChildScrollView(child: child);'));
  });

  test('settings receipt panel exposes printer destination CRUD surface', () {
    final source = readRepoFile('lib/features/admin/tabs/settings_tab.dart');
    final provider = readRepoFile(
      'lib/features/admin/providers/printer_destinations_provider.dart',
    );
    final service = readRepoFile(
      'lib/core/services/printer_destination_service.dart',
    );

    expect(source, contains('_buildPrinterDestinationsSection'));
    expect(source, contains("Key('settings_printer_destinations_section')"));
    expect(source, contains("Key('settings_printer_destination_add')"));
    expect(source, contains("Key('settings_printer_destination_edit')"));
    expect(source, contains("Key('settings_printer_destination_remove')"));
    expect(source, contains("'settings_printer_destination_delete_dialog'"));
    expect(source, contains("'settings_printer_destination_delete_confirm'"));
    expect(source, contains("Key('settings_printer_destination_test')"));
    expect(source, contains("Key('settings_print_station_open')"));
    expect(source, contains('settings_printer_destination_floor_label'));
    expect(source, contains('printerDestinationsProvider(storeId)'));
    expect(source, contains('PrinterDestinationDraft('));
    expect(source, contains('testDestination(destination.id)'));
    expect(source, isNot(contains('PrintJobAgentService')));
    expect(source, isNot(contains('enqueueTestPrintJob(destination.id)')));
    expect(source, contains('context.go(\'/print-station\')'));
    expect(
      source,
      contains(
        "canAccessRouteForRole(ref.watch(authProvider).role, '/print-station')",
      ),
    );
    expect(source, contains('_printerDestinationErrorDetail'));
    expect(
      source,
      contains('context.l10n.settingsPrintRoutingDestinationsTitle'),
    );
    expect(source, contains('context.l10n.settingsTestPrintComplete'));
    expect(provider, contains('PrinterDestinationsNotifier'));
    expect(provider, contains('PrinterDestinationErrorCodes'));
    expect(provider, contains('Future<bool> upsertDestination'));
    expect(provider, contains('Future<bool> deleteDestination'));
    expect(provider, contains('Future<bool> enqueueTestPrintJob'));
    expect(service, contains("'admin_upsert_printer_destination_v3'"));
    expect(service, contains(".from('printer_endpoints')"));
    expect(service, contains("'admin_delete_printer_destination'"));
    expect(service, contains(".eq('is_active', true)"));
    expect(source, isNot(contains('CheckboxListTile(')));
    expect(service, contains("'admin_enqueue_printer_test_job'"));
    expect(service, isNot(contains(".update({")));
    expect(service, isNot(contains(".insert({")));
    expect(provider, isNot(contains('Enter a printer name.')));
    expect(provider, isNot(contains('Failed to save printer routing.')));
  });
}
