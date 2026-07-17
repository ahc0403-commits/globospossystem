import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
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

    expect(source, contains('viewport.maxWidth < 1120'));
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
    expect(source, contains("Key('settings_printer_destination_test')"));
    expect(source, contains("Key('settings_print_station_open')"));
    expect(source, contains('settings_printer_destination_floor_label'));
    expect(source, contains('printerDestinationsProvider(storeId)'));
    expect(source, contains('PrinterDestinationDraft('));
    expect(source, contains('enqueueTestPrintJob(destination.id)'));
    expect(source, isNot(contains('PrintJobAgentService')));
    expect(source, isNot(contains('testPrintDestination(destination.id)')));
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
    expect(source, contains('context.l10n.kitchenReprintQueued'));
    expect(provider, contains('PrinterDestinationsNotifier'));
    expect(provider, contains('PrinterDestinationErrorCodes'));
    expect(provider, contains('Future<bool> upsertDestination'));
    expect(provider, contains('Future<bool> deleteDestination'));
    expect(provider, contains('Future<bool> enqueueTestPrintJob'));
    expect(service, contains("'admin_upsert_printer_destination'"));
    expect(service, contains("'admin_delete_printer_destination'"));
    expect(service, contains("'admin_enqueue_printer_test_job'"));
    expect(service, isNot(contains(".update({")));
    expect(service, isNot(contains(".insert({")));
    expect(provider, isNot(contains('Enter a printer name.')));
    expect(provider, isNot(contains('Failed to save printer routing.')));
  });
}
