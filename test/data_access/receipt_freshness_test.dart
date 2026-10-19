import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_screen.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

class FixtureAuth extends AuthNotifier {
  FixtureAuth() : super() {
    state = const PosAuthState(role: 'store_admin', storeId: 'fixture-store');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'payment event refreshes exact summary and cursor page reuses it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final events = StreamController<PosLiveEvent>.broadcast();
      final calls = <Map<String, dynamic>>[];
      await tester.runAsync(() async {
        await Supabase.initialize(
          url: 'http://127.0.0.1:54321',
          anonKey: 'fixture',
          httpClient: MockClient((r) async {
            expect(r.url.path.endsWith('/get_receipt_ledger_page'), true);
            final params = jsonDecode(r.body) as Map<String, dynamic>;
            calls.add(params);
            return http.Response(
              jsonEncode({
                'business_date': params['p_business_date'],
                'generated_at': '2026-10-11T00:00:00Z',
                'summary': params['p_include_summary'] == true
                    ? {
                        'receipt_count': calls.length,
                        'gross_amount': 1000 * calls.length,
                        'net_amount': 1000 * calls.length,
                        'adjusted_amount': 0,
                      }
                    : null,
                'receipts': [],
                'has_more': false,
              }),
              200,
              request: r,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
      });
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const ReceiptLedgerScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => FixtureAuth()),
            posLiveEventsProvider.overrideWith((ref, scope) => events.stream),
          ],
          child: MaterialApp.router(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      events.add(
        const PosLiveEvent(
          domain: 'payments',
          sourceTable: 'payment_adjustments',
          eventType: 'UPDATE',
          restaurantId: 'fixture-store',
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect(calls.last['p_include_summary'], true);
      expect(calls.last['p_limit'], 50);
      await tester.runAsync(() async {
        final page = await receiptLedgerService.load(
          businessDate: '2026-10-11',
          storeId: 'fixture-store',
        );
        final cursorPage = await receiptLedgerService.load(
          businessDate: '2026-10-11',
          storeId: 'fixture-store',
          afterAt: DateTime.utc(2026, 10, 11),
          afterId: 'fixture-receipt',
          knownSummary: page.summary,
        );
        expect(calls.last['p_include_summary'], false);
        expect(cursorPage.summary.netAmount, page.summary.netAmount);
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await events.close();
      await tester.runAsync(() => Supabase.instance.dispose());
    },
  );
}
