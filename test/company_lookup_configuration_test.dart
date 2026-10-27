import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/company_tax_lookup_service.dart';
import 'package:globos_pos_system/features/red_invoice_intake/buyer_information_form.dart';
import 'package:globos_pos_system/features/red_invoice_intake/company_lookup_copy.dart';
import 'package:globos_pos_system/features/settings/company_lookup_settings_card.dart';
import 'company_tax_lookup_test.dart' as fixture;

void main() {
  test(
    'status shares in-flight reads but does not cache disabled settings',
    () async {
      var calls = 0;
      final pending = Completer<dynamic>();
      final service = CompanyTaxLookupService(
        transport: (_, code) async => fixture.success(code),
        statusTransport: (_) {
          calls++;
          return pending.future;
        },
        sessionScope: () => 'session',
      );
      addTearDown(service.dispose);
      final reads = List.generate(100, (_) => service.status(fixture.store));
      expect(calls, 1);
      pending.complete({'outcome': 'disabled'});
      expect(
        (await Future.wait(
          reads,
        )).every((s) => s.availability == CompanyLookupAvailability.disabled),
        isTrue,
      );
      await service.status(fixture.store);
      expect(calls, 2);
    },
  );

  test(
    'status bounds concurrency and discards previous-session responses',
    () async {
      var session = 'one';
      final pending = <Completer<dynamic>>[];
      final service = CompanyTaxLookupService(
        transport: (_, code) async => fixture.success(code),
        statusTransport: (_) {
          final c = Completer<dynamic>();
          pending.add(c);
          return c.future;
        },
        sessionScope: () => session,
      );
      addTearDown(service.dispose);
      final first = service.status('one');
      final second = service.status('two');
      expect(
        (await service.status('three')).availability,
        CompanyLookupAvailability.unavailable,
      );
      expect(pending.length, 2);
      session = 'two';
      service.clear();
      for (final c in pending) {
        c.complete({'outcome': 'enabled', 'can_manage': true});
      }
      expect((await first).availability, CompanyLookupAvailability.unavailable);
      expect((await second).canManage, isFalse);
    },
  );

  test(
    'saving configuration clears cached names and notifies live forms',
    () async {
      var names = 0, notifications = 0;
      final service = CompanyTaxLookupService(
        transport: (_, code) async {
          names++;
          return fixture.success(code);
        },
        settingTransport: (_, enabled) async => {
          'outcome': enabled ? 'enabled' : 'disabled',
          'configured': true,
          'can_manage': true,
        },
        sessionScope: () => 'one',
      );
      addTearDown(service.dispose);
      service.addListener(() => notifications++);
      await service.lookup(storeId: fixture.store, taxCode: fixture.code);
      await service.setEnabled(fixture.store, false);
      await service.lookup(storeId: fixture.store, taxCode: fixture.code);
      expect(names, 2);
      expect(notifications, 1);
    },
  );

  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets(
      'disabled store is explained before tax entry and can recover in $locale',
      (tester) async {
        var enabled = false, lookups = 0, reads = 0;
        final service = CompanyTaxLookupService(
          transport: (_, code) async {
            lookups++;
            return fixture.success(code, 'CÔNG TY TNHH SJ VINA');
          },
          statusTransport: (_) async {
            reads++;
            return {'outcome': enabled ? 'enabled' : 'disabled'};
          },
          sessionScope: () => 'one',
        );
        final c = BuyerInformationController({
          'buyer_address': 'Keep',
          'buyer_email': 'keep@example.invalid',
        });
        await tester.pumpWidget(fixture.app(c, service, locale: locale));
        await tester.pumpAndSettle();
        final copy = CompanyLookupCopy(locale);
        expect(
          find.text(copy.failure(CompanyLookupOutcome.disabled)),
          findsOneWidget,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('pos_company_lookup')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const Key('pos_buyer_number_value')),
          '0313431011',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(lookups, 0);
        expect(reads, 1);
        enabled = true;
        await tester.tap(find.byKey(const Key('pos_company_lookup_refresh')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('pos_company_lookup')));
        await tester.pumpAndSettle();
        expect(c.fields['buyer_legal_name']!.text, 'CÔNG TY TNHH SJ VINA');
        expect(c.fields['buyer_address']!.text, 'Keep');
        expect(c.fields['buyer_email']!.text, 'keep@example.invalid');
        expect(reads, 2);
        expect(lookups, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        service.dispose();
      },
    );
  }

  testWidgets(
    'late availability from another store cannot block the current form',
    (tester) async {
      final pending = Completer<dynamic>();
      final service = CompanyTaxLookupService(
        transport: (_, code) async => fixture.success(code),
        statusTransport: (store) => store == fixture.store
            ? pending.future
            : Future.value({'outcome': 'enabled'}),
        sessionScope: () => 'one',
      );
      final c = BuyerInformationController({
        'buyer_number_value': fixture.code,
      });
      await tester.pumpWidget(fixture.app(c, service, key: const Key('form')));
      await tester.pumpWidget(
        fixture.app(c, service, key: const Key('form'), storeId: 'other'),
      );
      await tester.pumpAndSettle();
      pending.complete({'outcome': 'disabled'});
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('pos_company_lookup')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      service.dispose();
    },
  );

  testWidgets('missing status RPC retains manual lookup compatibility', (
    tester,
  ) async {
    final service = CompanyTaxLookupService(
      transport: (_, code) async => fixture.success(code),
      statusTransport: (_) async => throw StateError('not deployed'),
      sessionScope: () => 'one',
    );
    final c = BuyerInformationController({'buyer_number_value': fixture.code});
    await tester.pumpWidget(fixture.app(c, service));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pos_company_lookup')));
    await tester.pumpAndSettle();
    expect(c.fields['buyer_legal_name']!.text, fixture.company);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    service.dispose();
  });

  testWidgets(
    'settings card requires server management permission and saves explicit choice',
    (tester) async {
      var canManage = false, writes = 0;
      final service = CompanyTaxLookupService(
        transport: (_, code) async => fixture.success(code),
        statusTransport: (_) async => {
          'outcome': 'disabled',
          'configured': false,
          'can_manage': canManage,
        },
        settingTransport: (_, enabled) async {
          writes++;
          expect(enabled, isTrue);
          return {
            'outcome': enabled ? 'enabled' : 'disabled',
            'configured': true,
            'can_manage': true,
          };
        },
        sessionScope: () => 'one',
      );
      Widget card(String store) => MaterialApp(
        home: Scaffold(
          body: CompanyLookupSettingsCard(storeId: store, service: service),
        ),
      );
      await tester.pumpWidget(card('one'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('company_lookup_setting_switch')),
            )
            .onChanged,
        isNull,
      );
      canManage = true;
      await tester.pumpWidget(card('two'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('company_lookup_setting_switch')));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(
        find.byKey(const Key('company_lookup_setting_error')),
        findsNothing,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('company_lookup_setting_switch')),
            )
            .value,
        isTrue,
      );
      expect(find.text(CompanyLookupCopy('en').missing), findsNothing);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );
}
