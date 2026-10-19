import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/config/integration_availability.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/features/delivery/delivery_settlement_provider.dart';
import 'package:globos_pos_system/features/delivery/screens/delivery_settlement_tab.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test('no role can enter the retired Deliberry workspace', () {
    for (final role in [
      null,
      'admin',
      'store_admin',
      'brand_admin',
      'super_admin',
      'photo_objet_master',
      'cashier',
    ]) {
      expect(PermissionUtils.canAccessDeliverySettlement(role), isFalse);
    }
  });

  test(
    'direct provider calls stop before accessing an uninitialized DB',
    () async {
      final notifier = DeliverySettlementNotifier();
      addTearDown(notifier.dispose);
      await notifier.load('historical-store');
      expect(notifier.state.error, deliberryRetiredError);
      expect(notifier.state.isLoading, isFalse);
      await notifier.confirmReceived(
        'historical-settlement',
        'historical-store',
      );
      expect(notifier.state.error, deliberryRetiredError);
      expect(notifier.state.confirmingId, isNull);
    },
  );

  for (final locale in ['ko', 'en', 'vi']) {
    testWidgets('old Deliberry entry is closed in $locale without a DB', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: DeliverySettlementTab()),
          ),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(DeliverySettlementTab));
      expect(
        find.text(AppLocalizations.of(context)!.deliberryRetiredMessage),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  }
}
