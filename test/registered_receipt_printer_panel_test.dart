import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/print_agent_coordinator.dart';
import 'package:globos_pos_system/core/hardware/print_station_mode.dart';
import 'package:globos_pos_system/core/hardware/print_agent_coordinator_provider.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/printer_diagnostics.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/core/services/printer_destination_service.dart';
import 'package:globos_pos_system/features/admin/providers/printer_destinations_provider.dart';
import 'package:globos_pos_system/features/settings/registered_receipt_printer_panel.dart';
import 'package:globos_pos_system/features/settings/printer_diagnostic_view.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    await font.load();
  });
  testWidgets(
    'tests registered receipt route, ignores other purposes and old local IP',
    (tester) async {
      final driver = _Driver();
      final coordinator = PrintAgentCoordinator(
        agent: driver,
        preferenceStore: _Preferences(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            printAgentCoordinatorProvider.overrideWith((_) => coordinator),
            printAgentDriverProvider.overrideWithValue(driver),
            printerDestinationsProvider('store-a').overrideWith(
              (_) => _Destinations('store-a', [
                _destination(
                  'receipt-a',
                  'store-a',
                  'receipt',
                  '192.168.1.251',
                ),
                _destination('kitchen-a', 'store-a', 'kitchen', '192.168.1.47'),
                _destination(
                  'retired',
                  'store-a',
                  'receipt',
                  '192.168.68.251',
                  active: false,
                ),
              ]),
            ),
          ],
          child: _app(const RegisteredReceiptPrinterPanel(storeId: 'store-a')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('192.168.68.251'), findsNothing);
      await tester.tap(
        find.byKey(const Key('registered_receipt_connection_test')),
      );
      await tester.pumpAndSettle();
      expect(driver.calls, ['receipt-a:connect']);
      expect(find.textContaining('192.168.1.251:9100'), findsWidgets);
      expect(find.textContaining('시간이 초과'), findsOneWidget);
      await tester.tap(find.byKey(const Key('registered_receipt_test_print')));
      await tester.pumpAndSettle();
      expect(driver.calls, ['receipt-a:connect', 'receipt-a:print']);
    },
  );

  testWidgets('multiple receipt printers require explicit selection', (
    tester,
  ) async {
    final driver = _Driver();
    final coordinator = PrintAgentCoordinator(
      agent: driver,
      preferenceStore: _Preferences(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          printAgentCoordinatorProvider.overrideWith((_) => coordinator),
          printAgentDriverProvider.overrideWithValue(driver),
          printerDestinationsProvider('store-a').overrideWith(
            (_) => _Destinations('store-a', [
              _destination('one', 'store-a', 'receipt', '192.168.1.251'),
              _destination('two', 'store-a', 'receipt', '192.168.1.252'),
            ]),
          ),
        ],
        child: _app(const RegisteredReceiptPrinterPanel(storeId: 'store-a')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('registered_receipt_test_print')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('two').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('registered_receipt_test_print')));
    await tester.pumpAndSettle();
    expect(driver.calls, ['two:print']);
  });

  testWidgets(
    'printer_connection_diagnostic_dialog opens with endpoint and closes',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPrinterDiagnosticDialog(
                context,
                const PrinterTestReport(
                  result: PrintResult.connectionRefused,
                  attempts: [
                    PrinterEndpointAttempt(
                      type: 'wired',
                      address: '192.168.1.251:9100',
                      status: PrinterOperationStatus(
                        PrintResult.connectionRefused,
                        errorCode: 'SOCKET_10061',
                      ),
                    ),
                  ],
                ),
              ),
              child: const Icon(Icons.print),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('printer_connection_diagnostic_dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('192.168.1.251:9100'), findsOneWidget);
      expect(find.textContaining('연결을 거부'), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets(
      'diagnostics remain readable at phone width and 2x text ($locale)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final driver = _Driver();
        final coordinator = PrintAgentCoordinator(
          agent: driver,
          preferenceStore: _Preferences(),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              printAgentCoordinatorProvider.overrideWith((_) => coordinator),
              printAgentDriverProvider.overrideWithValue(driver),
              printerDestinationsProvider('store-a').overrideWith(
                (_) => _Destinations('store-a', [
                  _destination(
                    'Cashier',
                    'store-a',
                    'receipt',
                    '192.168.1.251',
                  ),
                ]),
              ),
            ],
            child: _app(
              const RegisteredReceiptPrinterPanel(storeId: 'store-a'),
              locale: locale,
              scale: 2,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('registered_receipt_connection_test')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('printer_diagnostic_result')),
          findsOneWidget,
        );
        final screenshotDir =
            Platform.environment['PRINT_DIAGNOSTIC_SCREENSHOT_DIR'];
        if (screenshotDir != null && locale == 'ko') {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('diagnosis_preview')),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$screenshotDir/connection-diagnosis-ko-phone.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}

Widget _app(Widget child, {String locale = 'ko', double scale = 1}) =>
    MaterialApp(
      theme: ThemeData(fontFamily: 'Pretendard'),
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RepaintBoundary(
        key: const Key('diagnosis_preview'),
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: child,
            ),
          ),
        ),
      ),
    );

PrinterDestinationConfig _destination(
  String id,
  String store,
  String purpose,
  String ip, {
  bool active = true,
}) => PrinterDestinationConfig(
  id: id,
  storeId: store,
  name: id,
  ip: ip,
  port: 9100,
  purpose: purpose,
  isActive: active,
  endpoints: [
    PrinterEndpointConfig(
      id: 'endpoint-$id',
      physicalPrinterId: id,
      type: 'wireless',
      ip: ip,
      deviceName: '',
      port: 9100,
      priority: 20,
      isActive: true,
    ),
  ],
);

class _Destinations extends PrinterDestinationsNotifier {
  _Destinations(super.storeId, List<PrinterDestinationConfig> destinations)
    : super(autoLoad: false) {
    state = PrinterDestinationsState(destinations: destinations);
  }
}

class _Preferences implements PrintAgentPreferenceStore {
  @override
  Future<PrintStationMode?> readMode() async => PrintStationMode.printer;
  @override
  Future<void> writeMode(PrintStationMode mode) async {}
  @override
  Future<bool> readEnabled() async => false;
  @override
  Future<void> writeEnabled(bool enabled) async {}
}

class _Driver implements PrintAgentDriver, DiagnosticPrintAgent {
  final calls = <String>[];
  @override
  bool get isSupported => true;
  @override
  Future<PrinterTestReport> diagnoseDestination(
    String id, {
    required bool printTicket,
  }) async {
    calls.add('$id:${printTicket ? 'print' : 'connect'}');
    return const PrinterTestReport(
      result: PrintResult.connectionTimeout,
      attempts: [
        PrinterEndpointAttempt(
          type: 'wireless',
          address: '192.168.1.251:9100',
          status: PrinterOperationStatus(
            PrintResult.connectionTimeout,
            errorCode: 'SOCKET_10060',
          ),
        ),
      ],
    );
  }

  @override
  Future<void> configureReceiptOnly(bool value) async {}
  @override
  Future<void> stopSafely() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
