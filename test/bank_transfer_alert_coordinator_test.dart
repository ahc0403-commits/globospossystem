import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_coordinator.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_sound.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('app-root alert loop survives route navigation', (tester) async {
    final startedAt = DateTime.now().toUtc();
    final alerts = _MutableAlertService(startedAt);
    final sound = _RecordingSoundService();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('vi'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => BankTransferAlertCoordinator(
            storeId: _storeId,
            alertService: alerts,
            soundService: sound,
            pollInterval: const Duration(milliseconds: 20),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const Key('open-next-route'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      body: Text('route-b', key: Key('route-b')),
                    ),
                  ),
                ),
                child: const Text('route-a'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-next-route')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('route-b')), findsOneWidget);

    alerts.items.add(
      BankTransferAlert(
        transactionId: 'route-transfer',
        providerTransactionId: 11,
        amount: 93456,
        paymentCode: 'GBROUTE',
        gateway: 'MSB',
        receivedAt: startedAt.add(const Duration(seconds: 1)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pump();

    expect(sound.amounts, [93456]);
    expect(find.textContaining('93.456 VND'), findsOneWidget);
    expect(alerts.savedProviderIds, [11]);

    await tester.pump(const Duration(milliseconds: 25));
    expect(sound.amounts, [93456]);
  });
}

class _MutableAlertService extends BankTransferAlertService {
  _MutableAlertService(this.startedAt);

  final DateTime startedAt;
  final List<BankTransferAlert> items = [];
  final List<int> savedProviderIds = [];

  @override
  Future<void> registerPollingDevice(String storeId) async {}

  @override
  Future<bool> acknowledge(String transactionId, {required bool spoken}) async {
    return true;
  }

  @override
  Future<List<BankTransferAlert>> fetchAfter(
    String storeId,
    BankTransferAlertCursor cursor, {
    int limit = 100,
  }) async => items.where(cursor.isBefore).take(limit).toList();

  @override
  Future<BankTransferAlertCursor?> loadCursor(String storeId) async {
    return BankTransferAlertCursor(
      receivedAt: startedAt,
      providerTransactionId: 0,
    );
  }

  @override
  Future<void> saveCursor(
    String storeId,
    BankTransferAlertCursor cursor,
  ) async {
    savedProviderIds.add(cursor.providerTransactionId);
  }
}

class _RecordingSoundService extends BankTransferAlertSoundService {
  final List<int> amounts = [];

  @override
  Future<void> prepare() async {}

  @override
  Future<void> play({required int amount}) async {
    amounts.add(amount);
  }
}
