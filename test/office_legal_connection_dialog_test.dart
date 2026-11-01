import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/super_admin/office_legal_connection_dialog.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'rollout capability disables new requests until a server verified refresh',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var ready = false;
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OfficeLegalConnectionDialog(
            actorId: 'synthetic-actor',
            entities: const [
              SuperTaxEntity(
                id: '30000000-0000-4000-8000-000000000001',
                name: 'Fixture',
                taxCode: 'TEST',
                ownerType: 'internal',
              ),
            ],
            rpc: (name, params) async {
              if (name == 'get_office_legal_capability_v1') {
                return {'contract_version': 1, 'ready': ready};
              }
              if (name == 'begin_office_legal_connection_v1') {
                writes++;
                return {
                  'state': 'awaiting_office',
                  'operation_id': params['p_operation_id'],
                };
              }
              return null;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final prepare = find.widgetWithText(
        FilledButton,
        'Prepare connection request',
      );
      expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
      expect(writes, 0);
      ready = true;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(prepare).onPressed, isNotNull);
      await tester.tap(prepare);
      await tester.pumpAndSettle();
      expect(writes, 1);
    },
  );
  test('pairing code round trips and rejects malformed/oversized inputs', () {
    final code = OfficeConnectionCode.create();
    final decoded = OfficeConnectionCode.decode(code.encode());
    expect(decoded.operationId, code.operationId);
    expect(decoded.proof, code.proof);
    for (final invalid in ['', 'not-a-code', 'GLOBOS-POS-1.${'x' * 1100}']) {
      expect(() => OfficeConnectionCode.decode(invalid), throwsFormatException);
    }
  });
  testWidgets(
    'lost creation response reuses the persisted operation and reads its result first',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      Map<String, dynamic>? committed;
      var writes = 0;
      final calls = <String>[];
      Future<dynamic> rpc(String name, Map<String, dynamic> params) async {
        calls.add(name);
        if (name == 'get_office_legal_capability_v1') {
          return {'contract_version': 1, 'ready': true};
        }
        if (name == 'get_office_legal_connection_for_entity_v1') return null;
        if (name == 'get_office_legal_connection_v1') return committed;
        writes++;
        committed = {
          'operation_id': params['p_operation_id'],
          'state': 'awaiting_office',
        };
        throw TimeoutException('acknowledgement lost after commit');
      }

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OfficeLegalConnectionDialog(
            actorId: 'synthetic-actor',
            rpc: rpc,
            entities: const [
              SuperTaxEntity(
                id: '30000000-0000-4000-8000-000000000001',
                name: 'New legal entity',
                taxCode: 'FIXTURE',
                ownerType: 'internal',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare connection request'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.textContaining('could not be confirmed'), findsOneWidget);
      await tester.tap(find.text('Prepare connection request'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(calls.last, 'get_office_legal_connection_v1');
      expect(find.text('Copy connection code'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(
        'office-legal-connection-v1:synthetic-actor:30000000-0000-4000-8000-000000000001',
      );
      expect(
        OfficeConnectionCode.decode(saved!).operationId,
        committed!['operation_id'],
      );
    },
  );
}
