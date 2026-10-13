import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/core/hardware/printer_diagnostics.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/core/hardware/wifi_printer_service.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/network_capability_service.dart';
import 'package:globos_pos_system/features/settings/printer_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'working OS route does not enumerate or bind unrelated adapters',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final sourceCalls = <String?>[];
      var enumerations = 0;
      final service = WifiPrinterService(
        socketConnector: (ip, port, source, timeout) {
          sourceCalls.add(source);
          return Socket.connect(ip, port, timeout: timeout);
        },
        sourceAddresses: (_) async {
          enumerations++;
          return ['192.168.100.2'];
        },
      );
      final accepted = server.listen((socket) => socket.destroy());
      addTearDown(accepted.cancel);
      expect(
        (await service.checkNetworkPrinter(
          '127.0.0.1',
          port: server.port,
        )).result,
        PrintResult.success,
      );
      expect(sourceCalls, [null]);
      expect(enumerations, 0);
    },
  );

  test('failed connections bound retries and retain the OS failure', () async {
    final calls = <String?>[];
    final service = WifiPrinterService(
      socketConnector: (_, _, source, _) async {
        calls.add(source);
        throw SocketException(
          'refused',
          osError: OSError('refused', source == null ? 10061 : 10051),
        );
      },
      sourceAddresses: (_) async => [
        '10.0.0.1',
        '10.0.0.1',
        '10.0.0.2',
        '10.0.0.3',
        '10.0.0.4',
      ],
    );
    final status = await service.checkNetworkPrinter('192.168.1.251');
    expect(status.result, PrintResult.connectionRefused);
    expect(status.errorCode, 'SOCKET_10061');
    expect(calls, [null, '10.0.0.1', '10.0.0.2', '10.0.0.3']);
    expect(status.mayHavePrinted, false);
  });

  test('invalid address and port send no network traffic', () async {
    var calls = 0;
    final service = WifiPrinterService(
      socketConnector: (_, _, _, _) async {
        calls++;
        throw StateError('must not connect');
      },
    );
    expect(
      (await service.checkNetworkPrinter('not an IP')).errorCode,
      'PRINTER_CONFIGURATION_INVALID',
    );
    expect(
      (await service.checkNetworkPrinter(
        '192.168.1.251',
        port: 65536,
      )).errorCode,
      'PRINTER_CONFIGURATION_INVALID',
    );
    expect(calls, 0);
  });

  test(
    'registered connection check uses its port without sending a test ticket',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = Completer<List<int>>();
      server.listen((socket) async {
        final bytes = <int>[];
        await for (final chunk in socket) {
          bytes.addAll(chunk);
        }
        socket.destroy();
        received.complete(bytes);
      });
      final backend = _Backend(
        PrintDestination(
          id: 'actual-receipt',
          name: 'Cashier',
          ip: '127.0.0.1',
          port: server.port,
          purpose: 'receipt',
        ),
      );
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: WifiPrinterService(),
        networkCapabilityService: _Network(),
      );
      final report = await agent.diagnoseDestination(
        'actual-receipt',
        printTicket: false,
      );
      expect(report.result, PrintResult.success);
      expect(report.attempts.single.address, '127.0.0.1:${server.port}');
      expect(
        await received.future.timeout(const Duration(seconds: 2)),
        isEmpty,
      );
      expect(backend.loads, 1);
    },
  );

  test(
    'failed registered test retains target and refusal instead of a generic result',
    () async {
      final backend = _Backend(
        const PrintDestination(
          id: 'actual-receipt',
          name: 'Cashier',
          ip: '192.168.1.251',
          port: 9100,
        ),
      );
      final service = WifiPrinterService(
        socketConnector: (_, _, _, _) async => throw const SocketException(
          'refused',
          osError: OSError('refused', 10061),
        ),
        sourceAddresses: (_) async => [],
      );
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: service,
        networkCapabilityService: _Network(),
      );
      final report = await agent.diagnoseDestination(
        'actual-receipt',
        printTicket: true,
      );
      expect(report.result, PrintResult.connectionRefused);
      expect(report.attempts.single.address, '192.168.1.251:9100');
      expect(report.attempts.single.status.errorCode, 'SOCKET_10061');
    },
  );

  test('possibly sent ticket never falls back to another endpoint', () async {
    final backend = _Backend(
      const PrintDestination(
        id: 'receipt',
        name: 'Receipt',
        ip: '192.168.1.251',
        port: 9100,
        endpoints: [
          PrinterEndpoint(
            id: 'first',
            type: PrinterEndpointType.wired,
            ip: '192.168.1.251',
            port: 9100,
            priority: 1,
            isActive: true,
          ),
          PrinterEndpoint(
            id: 'second',
            type: PrinterEndpointType.wireless,
            ip: '192.168.1.252',
            port: 9100,
            priority: 2,
            isActive: true,
          ),
        ],
      ),
    );
    final service = _AmbiguousService();
    final agent = PrintJobAgentService(
      backend: backend,
      printerService: service,
      networkCapabilityService: _Network(),
    );
    final report = await agent.diagnoseDestination(
      'receipt',
      printTicket: true,
    );
    expect(service.calls, ['192.168.1.251']);
    expect(report.result, PrintResult.connectionTimeout);
    expect(report.attempts.single.status.mayHavePrinted, true);
    expect(report.errorCode, startsWith('PARTIAL_PRINT:'));
  });

  test(
    'late preferences cannot restore an obsolete printer IP over user input',
    () async {
      SharedPreferences.setMockInitialValues({'printer_ip': '192.168.68.251'});
      final saved = await SharedPreferences.getInstance();
      final initial = Completer<SharedPreferences>();
      var calls = 0;
      final notifier = PrinterNotifier(
        preferences: () => ++calls == 1 ? initial.future : Future.value(saved),
      );
      addTearDown(notifier.dispose);
      await notifier.setIp('192.168.1.251');
      initial.complete(saved);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.printerIp, '192.168.1.251');
    },
  );

  test(
    'Windows connection probe sends no bytes and preserves spooler error',
    () async {
      const channel = MethodChannel('globos/usb_printer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'USB_PRINTER_OPEN_FAILED');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final status = await WifiPrinterService().checkUsbPrinter('Máy in USB');
      expect(status.errorCode, 'USB_PRINTER_OPEN_FAILED');
      expect(status.mayHavePrinted, false);
      expect(calls.single.method, 'testConnection');
      expect((calls.single.arguments as Map).containsKey('bytes'), false);
    },
    skip: !Platform.isWindows ? 'Runs in the exact-SHA Windows build.' : false,
  );
}

class _Backend implements PrintJobBackend {
  _Backend(this.destination);
  final PrintDestination destination;
  int loads = 0;
  @override
  Future<PrintDestination?> loadDestination(String id) async {
    loads++;
    return destination;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network implements NetworkCapabilityService {
  @override
  Future<NetworkCapabilities> loadCapabilities() async =>
      const NetworkCapabilities(wiredConnected: true, wirelessConnected: false);
}

class _AmbiguousService implements PrinterService, DiagnosticPrinterService {
  final calls = <String>[];
  @override
  bool get isSupported => true;
  @override
  Future<PrinterOperationStatus> printNetworkPrinter(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    calls.add(ip);
    return const PrinterOperationStatus(
      PrintResult.connectionTimeout,
      mayHavePrinted: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
