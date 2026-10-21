import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/store_workflow/preparation_board.dart';
import 'package:globos_pos_system/features/store_workflow/workflow_service.dart';
import 'package:globos_pos_system/features/store_workflow/workflow_setup_card.dart';

void main() {
  Future<void> setupCard(
    WidgetTester tester,
    List<String> actions, {
    bool device = false,
  }) async {
    final service = WorkflowService(
      rpc: (_, params) async {
        actions.add(params['p_action'] as String);
        return {
          'revision': 1,
          'candidate_id': 'candidate',
          'active_id': null,
          'draft': null,
          'current_workflow': 'kitchen_floor',
          'fulfillment_mode': 'paperless',
          'accounts': [
            {'id': 'user', 'name': 'Cook', 'kind': 'kitchen'},
          ],
          'devices': device
              ? [
                  {
                    'user_id': 'user',
                    'device_id': 'device',
                    'seen_at': '2026-10-21T10:00:00Z',
                    'pending_count': 0,
                  },
                ]
              : [],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkflowSetupCard(storeId: 'store', service: service),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Load setup'));
    await tester.pumpAndSettle();
  }

  testWidgets('route search closes without saving or selecting a menu', (
    tester,
  ) async {
    final actions = <String>[];
    await setupCard(tester, actions);
    await tester.ensureVisible(find.text('Add menu route'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add menu route'));
    await tester.pumpAndSettle();
    expect(find.text('Menu to route'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions, ['load']);
  });
  testWidgets(
    'activation confirmation can close without switching live configuration',
    (tester) async {
      final actions = <String>[];
      await setupCard(tester, actions);
      await tester.ensureVisible(find.text('Activate after device checks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activate after device checks'));
      await tester.pumpAndSettle();
      expect(find.text('Activate published setup'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(actions, ['load']);
    },
  );

  testWidgets('retiring an offline device requires explicit confirmation', (
    tester,
  ) async {
    final actions = <String>[];
    await setupCard(tester, actions, device: true);
    await tester.ensureVisible(find.byTooltip('Remove offline device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove offline device'));
    await tester.pumpAndSettle();
    expect(find.text('Remove offline device'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions, ['load']);
    await tester.tap(find.byTooltip('Remove offline device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
    expect(actions, ['load', 'retire_device']);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'durable workflow request remains scoped to its actor and store',
    () async {
      final first = WorkflowOutbox('store', 'actor');
      final request = {
        'p_event_id': 'event',
        'p_action': 'done',
        'p_allocations': [
          {'step_id': 'step', 'revision': 2, 'quantity': 1},
        ],
      };
      await first.save(request);
      expect(await WorkflowOutbox('store', 'actor').read(), request);
      expect(await WorkflowOutbox('other', 'actor').read(), isNull);
      expect(await WorkflowOutbox('store', 'other').read(), isNull);
      await expectLater(first.save(request), throwsStateError);
      await first.clear();
      expect(await first.read(), isNull);
    },
  );
  test(
    'KDS snapshots preserve workflow discovery through ordinary state updates',
    () {
      final state = EmergencyFulfillmentState.fromJson({
        'assigned': true,
        'active': true,
        'station_type': 'kitchen',
        'operating_workflow': {
          'active_id': 'release',
          'quiesced': false,
          'station': {'id': 'station'},
        },
      });
      expect(
        state.copyWith(isLoading: true).operatingWorkflow?['active_id'],
        'release',
      );
      expect(
        EmergencyFulfillmentState.fromJson({
          'assigned': true,
        }).operatingWorkflow,
        isNull,
      );
    },
  );
  Map<String, dynamic> workflow() => {
    'active_id': 'release',
    'candidate_id': 'release',
    'station': {'id': 'station', 'name': 'Kitchen 2'},
  };
  Map<String, dynamic> item({
    int started = 0,
    int done = 0,
    int revision = 0,
  }) => {
    'id': 'step',
    'task_id': 'task',
    'created_at': '2026-10-21T12:00:00Z',
    'position': 2,
    'started': started,
    'done': done,
    'revision': revision,
    'quantity': 3,
    'available': 2,
    'name_en': 'Noodles [Hot]',
    'name_ko': '면 [맵게]',
    'name_vi': 'Mì [Cay]',
    'table_number': '101',
    'floor_label': '2F',
    'notes': 'No onions',
    'final_step': true,
  };
  Future<void> board(
    WidgetTester tester,
    WorkflowService service, {
    Widget? packaging,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PreparationBoard(
          storeId: 'store',
          userId: 'actor',
          workflow: workflow(),
          service: service,
          packagingPanel: packaging,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'completed history uses the scoped query and explicit undo quantity',
    (tester) async {
      final calls = <Map<String, dynamic>>[];
      final service = WorkflowService(
        rpc: (name, params) async {
          calls.add({'name': name, ...params});
          if (name == 'store_preparation_snapshot_v1') {
            return {
              'release_id': 'release',
              'has_more': false,
              'items': [
                {
                  ...item(started: 2, done: 2, revision: 4),
                  'quantity': 2,
                  'undo_start_available': 0,
                  'undo_done_available': 1,
                },
              ],
            };
          }
          return <String, dynamic>{};
        },
      );
      await board(tester, service);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(calls.last['p_completed'], isTrue);
      await tester.ensureVisible(find.text('Undo completion'));
      await tester.tap(find.text('Undo completion'));
      await tester.pumpAndSettle();
      expect(find.text('Quantity to undo'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final event = calls.singleWhere(
        (c) => c['name'] == 'store_preparation_progress_v1',
      );
      expect(event['p_action'], 'undo_done');
      expect((event['p_allocations'] as List).single, {
        'step_id': 'step',
        'revision': 4,
        'quantity': 1,
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'explicit partial start precedes final handoff and keeps packaging visible',
    (tester) async {
      var row = item();
      final events = <Map<String, dynamic>>[];
      final service = WorkflowService(
        rpc: (name, params) async {
          if (name == 'store_preparation_snapshot_v1') {
            return {
              'release_id': 'release',
              'station': workflow()['station'],
              'has_more': false,
              'items': [row],
            };
          }
          if (name == 'store_preparation_progress_v1') {
            events.add(params);
            final quantity =
                (params['p_allocations'] as List).single['quantity'] as int;
            row = item(
              started:
                  row['started'] +
                  (params['p_action'] == 'start' ? quantity : 0),
              done: row['done'] + (params['p_action'] == 'done' ? quantity : 0),
              revision: row['revision'] + 1,
            );
            return {'event_id': params['p_event_id']};
          }
          return <String, dynamic>{};
        },
      );
      await board(
        tester,
        service,
        packaging: const Text('Existing packaging task'),
      );
      expect(find.text('Existing packaging task'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Final handoff'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Start cooking'));
      await tester.pumpAndSettle();
      expect(
        events,
        isEmpty,
        reason: 'Opening a quantity dialog must not start cooking',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(events.single['p_action'], 'start');
      expect((events.single['p_allocations'] as List).single['quantity'], 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Final handoff'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Final handoff'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(events.length, 2);
      expect(events.last['p_action'], 'done');
      expect((events.last['p_allocations'] as List).single['revision'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unknown response retries identical event and clears only after acknowledgement',
    (tester) async {
      var fail = true;
      final attempts = <Map<String, dynamic>>[];
      final request = {
        'p_event_id': 'durable-id',
        'p_action': 'start',
        'p_allocations': [
          {'step_id': 'step', 'revision': 0, 'quantity': 1},
        ],
      };
      await WorkflowOutbox('store', 'actor').save(request);
      final service = WorkflowService(
        rpc: (name, params) async {
          if (name == 'store_preparation_progress_v1') {
            attempts.add(params);
            if (fail) throw TimeoutException('lost response');
            return {'event_id': params['p_event_id']};
          }
          return {
            'release_id': 'release',
            'station': workflow()['station'],
            'items': [item(started: 1)],
            'has_more': false,
          };
        },
      );
      await board(tester, service);
      expect(await WorkflowOutbox('store', 'actor').read(), request);
      fail = false;
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(attempts.length, 2);
      expect(attempts.first, attempts.last);
      expect(await WorkflowOutbox('store', 'actor').read(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('server conflict retains request until explicit release', (
    tester,
  ) async {
    await WorkflowOutbox('store', 'actor').save({
      'p_event_id': 'id',
      'p_action': 'done',
      'p_allocations': [
        {'step_id': 'step', 'revision': 0, 'quantity': 1},
      ],
    });
    final service = WorkflowService(
      rpc: (name, params) async {
        if (name == 'store_preparation_progress_v1') {
          throw const PostgrestException(message: 'WORKFLOW_PROGRESS_CHANGED');
        }
        return {
          'release_id': 'release',
          'station': workflow()['station'],
          'items': [item(started: 2, revision: 3)],
          'has_more': false,
        };
      },
    );
    await board(tester, service);
    expect(await WorkflowOutbox('store', 'actor').read(), isNotNull);
    await tester.tap(find.text('Clear unapplied request'));
    await tester.pumpAndSettle();
    expect(await WorkflowOutbox('store', 'actor').read(), isNull);
    expect(find.text('Noodles [Hot]'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'setup follows save validate publish without implicit activation',
    (tester) async {
      final actions = <String>[];
      var revision = 0;
      Map<String, dynamic>? draft;
      String? proof;
      String? candidate;
      final service = WorkflowService(
        rpc: (name, params) async {
          final action = params['p_action'] as String;
          actions.add(action);
          if (action != 'load') {
            expect(params['p_expected_revision'], revision);
            revision++;
          }
          if (action == 'save') {
            draft = Map<String, dynamic>.from(params['p_definition'] as Map);
          }
          if (action == 'validate') proof = 'checked';
          if (action == 'publish') candidate = 'release';
          return {
            'restaurant_id': 'store',
            'revision': revision,
            'draft': draft,
            'validated_hash': proof,
            'candidate_id': candidate,
            'active_id': null,
            'current_workflow': 'kitchen_floor',
            'fulfillment_mode': 'paperless',
            'accounts': [
              {'id': 'kitchen-user', 'name': 'Kitchen user', 'kind': 'kitchen'},
            ],
            'devices': [],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorkflowSetupCard(storeId: 'store', service: service),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Load setup'));
      await tester.pumpAndSettle();
      for (final label in [
        'Save draft',
        'Validate and simulate',
        'Publish validated setup',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(actions, ['load', 'save', 'validate', 'publish']);
      expect(draft?['default_path'], [
        (draft?['stations'] as List).single['id'],
      ]);
      expect((draft?['stations'] as List).single['user_ids'], ['kitchen-user']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
