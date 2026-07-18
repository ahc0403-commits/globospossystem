import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/tabs/einvoice_tab.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('M-Invoice settings dialog executes from the Admin control', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          locale: const Locale('vi'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const EinvoiceTab(
            meInvoiceReadinessOverride: [
              {
                'tax_entity_id': 'tax-entity-1',
                'tax_code': '0312345678',
                'seller_name': 'GLOBOS Vietnam',
                'integration_status': 'needs_vendor_activation',
                'pending_manual_config_count': 1,
                'dispatch_paused_count': 0,
                'ready_to_dispatch': false,
                'blocking_reasons': ['integration_not_active'],
              },
            ],
            meInvoiceSellerConfigsOverride: [
              {
                'tax_entity_id': 'tax-entity-1',
                'tax_entity': {
                  'tax_code': '0312345678',
                  'name': 'GLOBOS Vietnam',
                },
                'app_id': '',
                'invoice_series': '',
                'integration_status': 'needs_vendor_activation',
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const Key('meinvoice_settings_action'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('meinvoice_settings_dialog'));
    expect(dialog, findsOneWidget);
    Navigator.of(tester.element(dialog)).pop();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
