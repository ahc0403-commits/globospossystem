import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';
import 'package:globos_pos_system/features/store_setup/widgets/physical_printer_form.dart';
import 'package:globos_pos_system/features/store_setup/widgets/printer_setup_step.dart';
import 'package:globos_pos_system/features/store_setup/widgets/route_preview.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('paperless derives only a typed USB cashier receipt without an IP', () {
    final printers = StoreOpeningTemplate.defaultPrinters();
    printers[PhysicalPrinterSlot.cashier] =
        printers[PhysicalPrinterSlot.cashier]!.copyWith(
          connection: SetupPrinterConnection.usb,
          usbPrinterName: 'XP-80C',
        );
    final draft = StoreOpeningDraft(
      storeId: 'store',
      printers: printers,
      operation: StorePrinterOperation.paperless,
    );
    expect(draft.requiredPrinterSlots, [PhysicalPrinterSlot.cashier]);
    expect(draft.destinations, hasLength(1));
    final receipt = draft.destinations.single;
    expect(receipt.purpose, 'receipt');
    expect(receipt.toJson(), containsPair('usb_printer_name', 'XP-80C'));
    expect(receipt.toJson(), containsPair('connection', 'usb'));
    expect(receipt.ip, isEmpty);
    expect(receipt.endpointLabel, 'USB · XP-80C');
    expect(
      draft.copyWith(operation: StorePrinterOperation.posPrint).destinations,
      hasLength(5),
    );
  });

  test(
    'load uses four store-scoped requests regardless of table count and embeds endpoints',
    () async {
      final calls = <Uri>[];
      final client = SupabaseClient(
        'https://setup.invalid',
        'fixture-anon',
        httpClient: MockClient((request) async {
          calls.add(request.url);
          final path = request.url.path.split('/').last;
          final Object response = switch (path) {
            'restaurants' => {'id': 'store', 'name': 'Fixture'},
            'restaurant_settings' => {
              'fulfillment_mode': 'paperless',
              'kds_workflow': 'kitchen_floor',
            },
            'tables' => List.generate(
              500,
              (i) => {
                'table_number': '$i',
                'seat_count': 4,
                'floor_label': '1F',
              },
            ),
            'printer_destinations' => [
              {
                'id': 'receipt',
                'purpose': 'receipt',
                'is_active': true,
                'physical_printers': {
                  'name': 'Cashier',
                  'printer_endpoints': [
                    {
                      'endpoint_type': 'usb',
                      'device_name': 'XP-80C',
                      'port': 9100,
                      'priority': 5,
                      'is_active': true,
                    },
                  ],
                },
              },
            ],
            _ => throw StateError('Unexpected request: $path'),
          };
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final config = await SupabaseStoreSetupBackend(
        client,
      ).loadExisting('store');
      expect(config.operation, StorePrinterOperation.paperless);
      expect(config.serviceWorkflow, StoreServiceWorkflow.kitchenFloor);
      expect(config.tables, hasLength(500));
      expect(calls, hasLength(4));
      expect(
        calls
            .where((uri) => uri.path.endsWith('printer_destinations'))
            .single
            .queryParameters['select'],
        contains('printer_endpoints('),
      );
      expect(
        calls.every(
          (uri) =>
              uri.queryParameters['restaurant_id'] == 'eq.store' ||
              uri.queryParameters['id'] == 'eq.store',
        ),
        isTrue,
      );
    },
  );

  test(
    'validate and apply send mode and typed USB endpoint in one RPC each',
    () async {
      final requests = <Map<String, dynamic>>[];
      final paths = <String>[];
      final client = SupabaseClient(
        'https://setup.invalid',
        'fixture-anon',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{"valid":true}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final printers = StoreOpeningTemplate.defaultPrinters();
      printers[PhysicalPrinterSlot.cashier] =
          printers[PhysicalPrinterSlot.cashier]!.copyWith(
            connection: SetupPrinterConnection.usb,
            usbPrinterName: 'XP-80C',
          );
      final draft = StoreOpeningDraft(
        storeId: 'store',
        printers: printers,
        operation: StorePrinterOperation.paperless,
      );
      final backend = SupabaseStoreSetupBackend(client);
      await backend.validate(draft);
      await backend.apply(draft);
      expect(paths, [
        '/rest/v1/rpc/admin_validate_store_opening_config_v3',
        '/rest/v1/rpc/admin_apply_store_opening_config_v3',
      ]);
      for (final payload in requests) {
        expect(payload['p_mode'], 'paperless');
        expect(payload['p_kds_workflow'], 'kitchen_tray_floor');
        final routes = payload['p_destinations'] as List;
        expect(routes, hasLength(1));
        expect(routes.single['usb_printer_name'], 'XP-80C');
      }
    },
  );

  testWidgets('service workflow is a separate store-level choice', (
    tester,
  ) async {
    final draft = StoreOpeningDraft(
      storeId: 'store',
      printers: StoreOpeningTemplate.defaultPrinters(),
      operation: StorePrinterOperation.paperless,
    );
    StoreServiceWorkflow? selected;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StoreSetupPrinterStep(
              draft: draft,
              onPrinterChanged: (_) {},
              onFloor1Changed: (_) {},
              onOperationChanged: (_) {},
              enabled: true,
              onServiceWorkflowChanged: (value) => selected = value,
            ),
          ),
        ),
      ),
    );
    final direct = find.byKey(const Key('store_setup_workflow_kitchen_floor'));
    await tester.ensureVisible(direct);
    await tester.tap(direct);
    expect(selected, StoreServiceWorkflow.kitchenFloor);
    expect(draft.serviceWorkflow, StoreServiceWorkflow.kitchenTrayFloor);
    expect(draft.copyWith(serviceWorkflow: selected).serviceWorkflow, selected);
    expect(find.text('주방 → 트레이 → 층 (분식클럽)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'five test destinations enqueue through one RPC and return five IDs',
    () async {
      var calls = 0;
      final client = SupabaseClient(
        'https://setup.invalid',
        'fixture-anon',
        httpClient: MockClient((request) async {
          calls++;
          expect(
            request.url.path,
            '/rest/v1/rpc/admin_enqueue_store_opening_tests',
          );
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['p_destination_ids'], hasLength(5));
          expect(payload['p_request_id'], isNotEmpty);
          return http.Response(
            jsonEncode([
              for (final id in payload['p_destination_ids'] as List)
                {'id': 'job-$id', 'destination_id': id, 'status': 'pending'},
            ]),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final routes = StoreOpeningTemplate.deriveDestinations(
        StoreOpeningTemplate.defaultPrinters(),
      );
      final jobs = await SupabaseStoreSetupBackend(client).enqueueTests(
        storeId: 'store',
        destinationsById: {for (final route in routes) route.label: route},
      );
      expect(calls, 1);
      expect(jobs.map((job) => job.label), routes.map((route) => route.label));
      expect(jobs.map((job) => job.jobId).toSet(), hasLength(5));
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('paperless/physical USB setup works at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (const bool.fromEnvironment('CAPTURE_SETUP')) {
        final loader = FontLoader('Pretendard')
          ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
        await loader.load();
      }
      var draft = StoreOpeningDraft(
        storeId: 'store',
        printers: StoreOpeningTemplate.defaultPrinters(),
        operation: StorePrinterOperation.paperless,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          theme: ThemeData(fontFamily: 'Pretendard'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: SingleChildScrollView(
                child: RepaintBoundary(
                  key: const Key('capture_setup'),
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          StoreSetupPrinterStep(
                            draft: draft,
                            enabled: true,
                            onOperationChanged: (mode) => setState(
                              () => draft = draft.copyWith(operation: mode),
                            ),
                            onPrinterChanged: (printer) => setState(
                              () => draft = draft.copyWith(
                                printers: {
                                  ...draft.printers,
                                  printer.slot: printer,
                                },
                              ),
                            ),
                            onFloor1Changed: (slot) => setState(
                              () => draft = draft.copyWith(floor1Slot: slot),
                            ),
                          ),
                          StoreSetupRoutePreview(
                            destinations: draft.destinations,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PhysicalPrinterForm), findsOneWidget);
      expect(
        find.byKey(const Key('store_setup_floor1_physical_slot')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('store_setup_connection_cashier')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store_setup_ip_cashier')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('store_setup_usb_cashier')),
        'XP-80C',
      );
      await tester.pumpAndSettle();
      expect(draft.destinations.single.usbPrinterName, 'XP-80C');
      expect(find.textContaining('USB · XP-80C'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width == 1200 && const bool.fromEnvironment('CAPTURE_SETUP')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture_setup')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/paperless-print-setup.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(
        find.byKey(const Key('store_setup_mode_pos_print')),
      );
      await tester.tap(find.byKey(const Key('store_setup_mode_pos_print')));
      await tester.pumpAndSettle();
      expect(find.byType(PhysicalPrinterForm), findsNWidgets(4));
      expect(draft.destinations, hasLength(5));
      expect(
        draft.printers[PhysicalPrinterSlot.cashier]!.usbPrinterName,
        'XP-80C',
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const Key('store_setup_mode_paperless')),
      );
      await tester.tap(find.byKey(const Key('store_setup_mode_paperless')));
      await tester.pumpAndSettle();
      expect(find.byType(PhysicalPrinterForm), findsOneWidget);
      expect(find.text('XP-80C'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
