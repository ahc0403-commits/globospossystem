import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/widgets/workforce_setup_card.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  testWidgets('provisioning success closes the transient password dialog', (
    tester,
  ) async {
    var receivedExpectedInput = false;
    await _pumpCard(
      tester,
      onProvision: ({required requirementId, required password}) async {
        receivedExpectedInput =
            requirementId == 'requirement-1' && password.length == 14;
        return true;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('store_setup_provision_requirement-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('store_setup_provision_password')),
      'valid-password',
    );
    await tester.enterText(
      find.byKey(const Key('store_setup_provision_password_confirmation')),
      'valid-password',
    );
    await tester.tap(find.byKey(const Key('store_setup_provision_submit')));
    await tester.pumpAndSettle();

    expect(receivedExpectedInput, isTrue);
    expect(
      find.byKey(const Key('store_setup_provision_account_dialog')),
      findsNothing,
    );
    expect(find.text('valid-password'), findsNothing);
  });

  testWidgets('provisioning failure restores the dialog immediately', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      onProvision: ({required requirementId, required password}) async => false,
    );

    await tester.tap(
      find.byKey(const ValueKey('store_setup_provision_requirement-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('store_setup_provision_password')),
      'valid-password',
    );
    await tester.enterText(
      find.byKey(const Key('store_setup_provision_password_confirmation')),
      'valid-password',
    );
    await tester.tap(find.byKey(const Key('store_setup_provision_submit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('store_setup_provision_account_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('store_setup_provision_error')),
      findsOneWidget,
    );
    final submit = tester.widget<FilledButton>(
      find.byKey(const Key('store_setup_provision_submit')),
    );
    expect(submit.onPressed, isNotNull);
  });

  testWidgets('template editor localizes codes and enforces short-code limit', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      onProvision: ({required requirementId, required password}) async => true,
    );

    await tester.tap(find.byKey(const Key('store_setup_configure_workforce')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('store_setup_short_code_field')),
      'ABCDEFGH',
    );
    final shortCodeField = tester.widget<TextField>(
      find.byKey(const Key('store_setup_short_code_field')),
    );
    expect(shortCodeField.controller!.text, 'ABCDEF');

    await tester.tap(
      find.byKey(const Key('store_setup_bunsik_workforce_preset')),
    );
    await tester.pumpAndSettle();
    expect(find.text('brand_admin'), findsNothing);
    expect(find.text('device_pos'), findsNothing);
    expect(find.text('photo_objet_store_operator'), findsNothing);
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required Future<bool> Function({
    required String requirementId,
    required String password,
  })
  onProvision,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView(
          children: [
            WorkforceSetupCard(
              store: const {'short_code': 'PHOTO'},
              readiness: const {
                'short_code': 'PHOTO',
                'management_model': 'brand_centralized',
                'account_templates_configured': true,
                'accounts_ready': false,
                'employees_active': 1,
                'missing_accounts': [
                  {
                    'requirement_id': 'requirement-1',
                    'account_code': 'photo_ops1',
                    'email': 'photo_ops1@globos.world',
                  },
                ],
              },
              isSaving: false,
              onSave:
                  ({
                    required shortCode,
                    required managementModel,
                    required brandManagerSlots,
                    required accountTemplates,
                  }) async => true,
              onRefresh: () async {},
              onProvision: onProvision,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
