import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
  });

  testWidgets('cash count changes never round the deposit preview or history', (
    tester,
  ) async {
    const storeId = '00000000-0000-0000-0000-000000000001';
    final calls = <String>[];
    Map<String, dynamic>? saved;
    var closed = false;
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: 'http://127.0.0.1:54321',
        anonKey: 'fixture',
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
        httpClient: MockClient((request) async {
          final name = request.url.path.split('/').last;
          calls.add(name);
          final params = jsonDecode(request.body) as Map<String, dynamic>;
          expect(params['p_store_id'], storeId);
          const ledger = {
            'closing_date': '2026-10-15',
            'payments_cash': 1622160,
            'payments_total': 1622160,
            'opening_cash_amount': 5000000,
            'expected_cash_amount': 6622160,
          };
          final Object response;
          switch (name) {
            case 'get_daily_closing_deposit_days':
              response = [
                {
                  ...ledger,
                  'close_source': closed ? 'manual' : 'scheduled',
                  'counted_cash_amount': closed ? 6623000 : 0,
                  'cash_variance': closed ? 840 : 0,
                },
              ];
            case 'get_daily_closing_cash_preview':
              response = ledger;
            case 'create_daily_closing':
              saved = params;
              closed = true;
              response = {'deposit_amount': 1623000};
            default:
              throw StateError('Unexpected RPC: $name');
          }
          return http.Response(
            jsonEncode(response),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });
    addTearDown(() => Supabase.instance.dispose());
    await tester.binding.setSurfaceSize(const Size(1024, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => RepaintBoundary(
            key: const Key('closing_precision_scene'),
            child: child!,
          ),
          home: const DailyClosingScreen(storeId: storeId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('daily_closing_action_2026-10-15'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daily_closing_cash_dialog')), findsOneWidget);

    Future<void> enterCount(int denomination, String count) async {
      final field = find.byKey(Key('daily_closing_note_$denomination'));
      await tester.ensureVisible(field);
      await tester.enterText(field, count);
      await tester.pumpAndSettle();
    }

    String? amount(String id) =>
        tester.widget<Text>(find.byKey(Key('${id}_amount'))).data;

    Future<void> capture(String name) async {
      final output = Platform.environment['GLOBOS_DEPOSIT_SCENES'];
      if (output == null) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('closing_precision_scene')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$output/$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await enterCount(500000, '13');
    await enterCount(1000, '123');
    expect(amount('daily_closing_deposit_preview'), '1.622.160 VND');
    expect(find.text('실사 현금 − 시재: 1.623.000 VND'), findsOneWidget);
    expect(find.text('840 VND'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('daily_closing_deposit_preview')),
    );
    await tester.pumpAndSettle();
    await capture('closing_preview');
    await enterCount(1000, '124');
    expect(amount('daily_closing_deposit_preview'), '1.622.160 VND');
    expect(find.text('실사 현금 − 시재: 1.624.000 VND'), findsOneWidget);
    expect(find.text('1.840 VND'), findsOneWidget);
    await enterCount(1000, '123');
    final confirm = find.byKey(const Key('daily_closing_cash_confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(saved!['p_opening_cash_amount'], 5000000);
    expect(saved!['p_closing_date'], '2026-10-15');
    final notes = saved!['p_cash_denominations'] as Map<String, dynamic>;
    expect(notes['500000'], 13);
    expect(notes['1000'], 123);
    expect(amount('closing_deposit_2026-10-15'), '1.622.160 VND');
    expect(find.text('실사 현금 − 시재: 1.623.000 VND'), findsOneWidget);
    expect(find.text('840 VND'), findsOneWidget);
    expect(calls, [
      'get_daily_closing_deposit_days',
      'get_daily_closing_cash_preview',
      'create_daily_closing',
      'get_daily_closing_deposit_days',
    ]);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const Key('closing_deposit_2026-10-15')),
    );
    await tester.pumpAndSettle();
    await capture('closing_history');
    await tester.pumpWidget(const SizedBox());
  });
}
