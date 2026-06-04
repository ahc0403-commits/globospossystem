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
}
