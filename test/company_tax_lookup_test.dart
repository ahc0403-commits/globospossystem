import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/company_tax_lookup_service.dart';
import 'package:globos_pos_system/features/red_invoice_intake/buyer_information_form.dart';
import 'package:globos_pos_system/features/red_invoice_intake/buyer_number.dart';
import 'package:globos_pos_system/features/red_invoice_intake/company_lookup_copy.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

const code = '0316794479';
const company = 'CÔNG TY TNHH CASSO';
const store = '20000000-0000-0000-0000-000000000001';
Map<String, dynamic> success(String number, [String name = company]) => {
  'outcome': 'success',
  'tax_code': number,
  'company_name': name,
  'source': 'esgoo',
  'fetched_at': '2026-10-11T01:00:00Z',
};
Widget app(
  BuyerInformationController controller,
  CompanyTaxLookupService service, {
  String locale = 'en',
  String storeId = store,
  Key? key,
}) => MaterialApp(
  theme: ThemeData(fontFamily: 'LookupPreview'),
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: RepaintBoundary(
          key: const Key('lookup_preview'),
          child: ColoredBox(
            color: Colors.white,
            child: BuyerInformationFields(
              key: key,
              controller: controller,
              storeId: storeId,
              lookupService: service,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('conservative names preserve accents and legal words', () {
    expect(companyNamesMatch(' công  ty tnhh casso ', company), isTrue);
    expect(companyNamesMatch('CONG TY TNHH CASSO', company), isFalse);
    expect(companyNamesMatch('CASSO', company), isFalse);
  });
  test(
    'strict result contract rejects mismatched codes, malformed names and source',
    () {
      for (final raw in [
        success('0000000000'),
        success(code, ' '),
        success(code, 'a' * 301),
        {...success(code), 'source': 'other'},
        {...success(code), 'fetched_at': 'bad'},
        {...success(code), 'company_name': 12},
      ]) {
        expect(
          CompanyLookupResult.parse(raw, code).outcome,
          CompanyLookupOutcome.unavailable,
        );
      }
    },
  );
  test(
    '100 same-code callers share one request; cache hit makes zero requests',
    () async {
      var calls = 0;
      final pending = Completer<dynamic>();
      final service = CompanyTaxLookupService(
        transport: (_, _) {
          calls++;
          return pending.future;
        },
        sessionScope: () => 'session-one',
      );
      addTearDown(service.dispose);
      final started = DateTime.now();
      final requests = List.generate(
        100,
        (_) => service.lookup(storeId: store, taxCode: code),
      );
      expect(calls, 1);
      pending.complete(success(code));
      expect(
        (await Future.wait(requests)).every((r) => r.companyName == company),
        isTrue,
      );
      await service.lookup(storeId: store, taxCode: code);
      expect(calls, 1);
      // Measured against the real service and injected transport, not provider load.
      // ignore: avoid_print
      print(
        'COMPANY_LOOKUP_MEASURE callers=100 requests=$calls warm_requests=0 elapsed_us=${DateTime.now().difference(started).inMicroseconds}',
      );
    },
  );
  test(
    'TTL, store, login, failed results and 50-entry capacity are bounded',
    () async {
      var calls = 0, session = 'one';
      var clock = DateTime.utc(2026);
      var unavailable = false;
      final service = CompanyTaxLookupService(
        transport: (_, number) async {
          calls++;
          return unavailable ? {'outcome': 'unavailable'} : success(number);
        },
        sessionScope: () => session,
        clock: () => clock,
      );
      addTearDown(service.dispose);
      await service.lookup(storeId: store, taxCode: code);
      clock = clock.add(const Duration(minutes: 5));
      await service.lookup(storeId: store, taxCode: code);
      expect(calls, 2);
      await service.lookup(storeId: 'other-store', taxCode: code);
      expect(calls, 3);
      session = 'two';
      await service.lookup(storeId: store, taxCode: code);
      expect(calls, 4);
      session = '';
      service.clear();
      expect(
        (await service.lookup(storeId: store, taxCode: code)).outcome,
        CompanyLookupOutcome.forbidden,
      );
      session = 'three';
      unavailable = true;
      await service.lookup(storeId: store, taxCode: code);
      await service.lookup(storeId: store, taxCode: code);
      expect(calls, 6);
      unavailable = false;
      for (var i = 0; i < 51; i++) {
        await service.lookup(
          storeId: store,
          taxCode: i.toString().padLeft(10, '0'),
        );
      }
      await service.lookup(storeId: store, taxCode: '0000000000');
      expect(calls, 58);
    },
  );
  test(
    'different requests have concurrency cap 2 and login change discards pending results',
    () async {
      var session = 'one', calls = 0;
      final pending = <Completer<dynamic>>[];
      final service = CompanyTaxLookupService(
        transport: (_, _) {
          calls++;
          final c = Completer<dynamic>();
          pending.add(c);
          return c.future;
        },
        sessionScope: () => session,
      );
      addTearDown(service.dispose);
      final first = service.lookup(storeId: store, taxCode: code);
      final second = service.lookup(storeId: store, taxCode: '0316956049');
      expect(
        (await service.lookup(storeId: store, taxCode: '0012345678')).outcome,
        CompanyLookupOutcome.rateLimited,
      );
      expect(calls, 2);
      session = 'two';
      service.clear();
      pending[0].complete(success(code));
      pending[1].complete(success('0316956049'));
      expect((await first).outcome, CompanyLookupOutcome.unavailable);
      expect((await second).outcome, CompanyLookupOutcome.unavailable);
      final third = service.lookup(storeId: store, taxCode: code);
      pending[2].complete(success(code));
      await third;
      expect(calls, 3);
    },
  );

  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets(
      'name-only fill and mismatch preserve original across retries in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var calls = 0;
        final service = CompanyTaxLookupService(
          transport: (_, number) async {
            calls++;
            return success(number);
          },
          sessionScope: () => 'one',
        );
        final c = BuyerInformationController({
          'buyer_number_value': code,
          'buyer_legal_name': 'Customer Company',
          'buyer_address': 'Keep address',
          'buyer_phone': 'Keep phone',
          'buyer_email': 'keep@example.invalid',
        });
        if (locale == 'en') {
          await tester.runAsync(() async {
            await (FontLoader('LookupPreview')..addFont(
                  rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf'),
                ))
                .load();
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
        }
        await tester.pumpWidget(app(c, service, locale: locale));
        await tester.tap(find.byKey(const Key('pos_company_lookup')));
        await tester.pumpAndSettle();
        expect(c.fields['buyer_legal_name']!.text, company);
        expect(find.text(CompanyLookupCopy(locale).mismatch), findsOneWidget);
        expect(find.textContaining('Customer Company'), findsOneWidget);
        expect(c.fields['buyer_address']!.text, 'Keep address');
        expect(c.fields['buyer_phone']!.text, 'Keep phone');
        expect(c.fields['buyer_email']!.text, 'keep@example.invalid');
        await tester.tap(find.byKey(const Key('pos_company_lookup')));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.textContaining('Customer Company'), findsOneWidget);
        if (locale == 'en') {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('lookup_preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/pos-company-lookup-preview.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        service.dispose();
      },
    );
  }
  testWidgets('Enter and blur auto-fill without requiring remaining fields', (
    tester,
  ) async {
    var calls = 0;
    final service = CompanyTaxLookupService(
      transport: (_, number) async {
        calls++;
        return success(number);
      },
      sessionScope: () => 'one',
    );
    final c = BuyerInformationController({});
    await tester.pumpWidget(app(c, service));
    await tester.enterText(
      find.byKey(const Key('pos_buyer_number_value')),
      code,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.fields['buyer_legal_name']!.text, company);
    expect(calls, 1);
    c.fields['buyer_number_value']!.text = '0316956049';
    expect(c.fields['buyer_legal_name']!.text, '');
    await tester.tap(find.byKey(const Key('pos_buyer_number_value')));
    await tester.tap(find.byKey(const Key('pos_buyer_legal_name')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(c.fields['buyer_legal_name']!.text, company);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    service.dispose();
  });
  testWidgets(
    'manual name edits, number changes, store switches and disposal ignore late responses',
    (tester) async {
      final pending = <Completer<dynamic>>[];
      final service = CompanyTaxLookupService(
        transport: (_, _) {
          final c = Completer<dynamic>();
          pending.add(c);
          return c.future;
        },
        sessionScope: () => 'one',
      );
      final c = BuyerInformationController({
        'buyer_number_value': code,
        'buyer_legal_name': 'Original',
      });
      const key = Key('shared-form');
      await tester.pumpWidget(app(c, service, key: key));
      await tester.tap(find.byKey(const Key('pos_company_lookup')));
      await tester.pump();
      c.fields['buyer_legal_name']!.text = 'New customer name';
      pending[0].complete(success(code));
      await tester.pumpAndSettle();
      expect(c.fields['buyer_legal_name']!.text, 'New customer name');
      c.fields['buyer_number_value']!.text = '0316956049';
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos_company_lookup')));
      await tester.pump();
      c.fields['buyer_number_value']!.text = '0012345678';
      pending[1].complete(success('0316956049'));
      await tester.pumpAndSettle();
      expect(c.fields['buyer_legal_name']!.text, 'New customer name');
      await tester.tap(find.byKey(const Key('pos_company_lookup')));
      await tester.pump();
      await tester.pumpWidget(
        app(c, service, key: key, storeId: 'other-store'),
      );
      pending[2].complete(success('0012345678'));
      await tester.pumpAndSettle();
      expect(c.fields['buyer_legal_name']!.text, 'New customer name');
      await tester.tap(find.byKey(const Key('pos_company_lookup')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      pending[3].complete(success('0012345678'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      service.dispose();
    },
  );
  testWidgets('failures preserve manual name and other ID types do not query', (
    tester,
  ) async {
    var calls = 0;
    final service = CompanyTaxLookupService(
      transport: (_, _) async {
        calls++;
        return {'outcome': 'unavailable'};
      },
      sessionScope: () => 'one',
    );
    final c = BuyerInformationController({
      'buyer_number_value': code,
      'buyer_legal_name': 'Original',
    });
    await tester.pumpWidget(app(c, service));
    await tester.tap(find.byKey(const Key('pos_company_lookup')));
    await tester.pumpAndSettle();
    expect(c.fields['buyer_legal_name']!.text, 'Original');
    expect(
      find.text(
        CompanyLookupCopy('en').failure(CompanyLookupOutcome.unavailable),
      ),
      findsOneWidget,
    );
    c.type = BuyerNumberType.personal;
    await tester.pumpWidget(app(c, service));
    expect(find.byKey(const Key('pos_company_lookup')), findsNothing);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    service.dispose();
  });
}
