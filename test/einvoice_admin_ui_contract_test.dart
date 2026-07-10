import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('einvoice admin surface stays exception-queue first', () {
    final source = readRepoFile('lib/features/admin/tabs/einvoice_tab.dart');

    expect(source, contains('_buildEinvoiceExceptionHeader'));
    expect(source, contains('_buildEinvoiceQueueControls'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("Key('einvoice_job_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, contains(".from('meinvoice_jobs')"));
    expect(source, contains('meinvoice_dispatch_enabled'));
    expect(source, contains('_meinvoiceReadinessProvider'));
    expect(source, contains('get_meinvoice_readiness'));
    expect(source, contains('_buildReadinessAlerts'));
    expect(source, contains('einvoiceMeInvoiceSetupRequired'));
    expect(source, contains('_meinvoiceJobEventsProvider'));
    expect(source, contains(".from('meinvoice_job_events')"));
    expect(source, contains("Key('meinvoice_job_event_history')"));
    expect(source, contains('einvoiceEventHistory'));
    expect(source, isNot(contains('raw_request')));
    expect(source, isNot(contains('raw_response')));
    expect(source, contains('_meinvoiceSellerConfigsProvider'));
    expect(source, contains('_openMeInvoiceConfigDialog'));
    expect(source, contains('admin_upsert_meinvoice_tax_entity_config'));
    expect(source, contains('admin_release_meinvoice_ready_jobs'));
    expect(source, contains('_releaseReadyMeInvoiceJobs'));
    expect(source, contains('einvoiceMeInvoiceReleaseReadyJobs'));
    expect(source, contains("Key('meinvoice_app_id_input')"));
    expect(source, contains("Key('meinvoice_invoice_series_input')"));
    expect(source, contains('einvoiceMeInvoiceSettings'));
    expect(source, contains('admin_retry_meinvoice_job'));
    expect(source, contains('admin_mark_resolved_meinvoice_job'));
    expect(source, isNot(contains('wetax_dispatch_enabled')));
    expect(source, isNot(contains('wetax_polling_enabled')));
    expect(source, isNot(contains('MISA_MEINVOICE_PASSWORD')));
    expect(source, isNot(contains("'meinvoice_dispatch_enabled': 'true'")));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
  });

  test('einvoice MISA settings labels are localized', () {
    final en = readRepoFile('lib/l10n/app_en.arb');
    final ko = readRepoFile('lib/l10n/app_ko.arb');
    final vi = readRepoFile('lib/l10n/app_vi.arb');

    for (final source in [en, ko, vi]) {
      expect(source, contains('einvoiceMeInvoiceSettings'));
      expect(source, contains('einvoiceMeInvoiceSettingsTitle'));
      expect(source, contains('einvoiceMeInvoiceSellerProfile'));
      expect(source, contains('einvoiceMeInvoiceIntegrationStatus'));
      expect(source, contains('einvoiceMeInvoiceAppId'));
      expect(source, contains('einvoiceMeInvoiceInvoiceSeries'));
      expect(source, contains('einvoiceMeInvoiceConfigSaved'));
      expect(source, contains('einvoiceMeInvoiceConfigSaveFailedWithError'));
      expect(source, contains('einvoiceEventHistory'));
      expect(source, contains('einvoiceEventHistoryEmpty'));
      expect(source, contains('einvoiceEventHistoryLoadFailed'));
      expect(source, contains('einvoiceEventRetryCount'));
      expect(source, contains('einvoiceMeInvoiceReleaseReadyJobs'));
      expect(source, contains('einvoiceMeInvoiceReleaseReadyJobsDone'));
      expect(
        source,
        contains('einvoiceMeInvoiceReleaseReadyJobsFailedWithError'),
      );
    }
  });

  test(
    'einvoice compact stack delegates queue and detail scrolling to parent',
    () {
      final source = readRepoFile('lib/features/admin/tabs/einvoice_tab.dart');

      expect(source, contains('viewport.maxWidth < 1120'));
      expect(source, contains('ToastResponsiveScrollBody('));
      expect(source, contains('scrollable: false'));
      expect(source, contains('scrollable: true'));
      expect(source, contains('shrinkWrap: !scrollable'));
      expect(source, contains('NeverScrollableScrollPhysics'));
      expect(source, contains('required bool scrollable'));
      expect(
        source,
        isNot(contains('SizedBox(height: 420, child: queuePane)')),
      );
    },
  );
}
