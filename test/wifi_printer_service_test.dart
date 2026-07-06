import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/core/hardware/wifi_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WifiPrinterService', () {
    test(
      'testConnection returns true when printer socket accepts connections',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final service = WifiPrinterService();

        final accepted = Completer<void>();
        unawaited(
          server.first.then((socket) async {
            await socket.close();
            accepted.complete();
          }),
        );

        final ok = await service.testConnection(
          server.address.address,
          port: server.port,
        );

        expect(ok, isTrue);
        await accepted.future;
      },
    );

    test('printReceipt writes ESC/POS bytes to the socket', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final service = WifiPrinterService();
      final expected = <int>[0x1B, 0x40, 0x48, 0x69];

      final received = Completer<List<int>>();
      unawaited(
        server.first.then((socket) async {
          final buffer = <int>[];
          await for (final chunk in socket) {
            buffer.addAll(chunk);
          }
          await socket.close();
          received.complete(buffer);
        }),
      );

      final result = await service.printReceipt(
        server.address.address,
        expected,
        port: server.port,
      );

      expect(result, PrintResult.success);
      expect(await received.future, expected);
    });

    test(
      'printReceipt reports connection failure for unreachable endpoint',
      () async {
        final service = WifiPrinterService();
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        await server.close();

        final result = await service.printReceipt(
          InternetAddress.loopbackIPv4.address,
          const [0x1B, 0x40],
          port: port,
        );

        expect(result, PrintResult.connectionFailed);
      },
    );

    test(
      'printReceipt rejects empty print payload before opening socket',
      () async {
        final service = WifiPrinterService();

        final result = await service.printReceipt(
          InternetAddress.loopbackIPv4.address,
          const <int>[],
        );

        expect(result, PrintResult.printFailed);
      },
    );
  });

  group('PrintJobAgentService', () {
    test('processOnce claims jobs, prints, and completes success', () async {
      final backend = _FakePrintJobBackend(
        jobs: [_job(id: 'job-1', destinationId: 'dest-1', ticketType: 'tray')],
        destinations: const {
          'dest-1': PrintDestination(
            id: 'dest-1',
            name: 'Tray',
            ip: '192.168.1.50',
            port: 9100,
          ),
        },
      );
      final printer = _FakePrinterService(PrintResult.success);
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      expect(backend.claimedStoreId, 'store-1');
      expect(backend.completed, [const _Completion(jobId: 'job-1', ok: true)]);
      expect(printer.prints.single.ip, '192.168.1.50');
      expect(printer.prints.single.port, 9100);
      expect(
        String.fromCharCodes(printer.prints.single.bytes),
        contains('TRAY'),
      );
    });

    test('processOnce completes failed when printing fails', () async {
      final backend = _FakePrintJobBackend(
        jobs: [_job(id: 'job-2', destinationId: 'dest-2', ticketType: 'floor')],
        destinations: const {
          'dest-2': PrintDestination(
            id: 'dest-2',
            name: 'Floor',
            ip: '192.168.1.51',
            port: 9101,
          ),
        },
      );
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: _FakePrinterService(PrintResult.connectionFailed),
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.connectionFailed);
      expect(backend.completed, [
        const _Completion(jobId: 'job-2', ok: false, error: 'connectionFailed'),
      ]);
    });

    test(
      'processOnce is a no-op when printer backend is unsupported',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: [
            _job(id: 'job-3', destinationId: 'dest-3', ticketType: 'kitchen'),
          ],
        );
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: _UnsupportedPrinterService(),
        );

        final results = await agent.processOnce('store-1');

        expect(results, isEmpty);
        expect(backend.claimedStoreId, isNull);
      },
    );

    test(
      'testPrintDestination prints directly to the selected destination',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: const [],
          destinations: const {
            'dest-test': PrintDestination(
              id: 'dest-test',
              name: '2F Printer',
              ip: '192.168.1.77',
              port: 9102,
            ),
          },
        );
        final printer = _FakePrinterService(PrintResult.success);
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
        );

        final result = await agent.testPrintDestination('dest-test');

        expect(result, PrintResult.success);
        expect(printer.prints.single.ip, '192.168.1.77');
        expect(printer.prints.single.port, 9102);
        expect(
          String.fromCharCodes(printer.prints.single.bytes),
          contains('TEST'),
        );
        expect(backend.completed, isEmpty);
      },
    );

    test(
      'startPolling subscribes to realtime and reacts to job changes',
      () async {
        final backend = _FakePrintJobBackend(jobs: const []);
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: _FakePrinterService(PrintResult.success),
        );

        agent.startPolling('store-1', interval: const Duration(hours: 1));
        await Future<void>.delayed(Duration.zero);
        final afterInitialClaim = backend.claimCount;
        backend.triggerPrintJobChange();
        await Future<void>.delayed(Duration.zero);
        agent.stop();

        expect(backend.subscribedStoreId, 'store-1');
        expect(backend.claimCount, afterInitialClaim + 1);
        expect(backend.unsubscribeCount, 1);
      },
    );
  });
}

PrintAgentJob _job({
  required String id,
  required String destinationId,
  required String ticketType,
}) {
  return PrintAgentJob(
    id: id,
    destinationId: destinationId,
    ticket: PrintTicket(
      ticket: ticketType,
      floorLabel: '2F',
      tableNumber: 'T07',
      ticketCode: 'abc12345',
      batchNo: 1,
      printedReason: 'initial',
      printedAt: '2026-07-06T12:00:00+07:00',
      items: const [PrintTicketItem(label: 'Pho Bo', quantity: 1)],
    ),
  );
}

class _FakePrintJobBackend implements PrintJobBackend {
  _FakePrintJobBackend({required this.jobs, this.destinations = const {}});

  final List<PrintAgentJob> jobs;
  final Map<String, PrintDestination> destinations;
  final completed = <_Completion>[];
  String? claimedStoreId;
  String? subscribedStoreId;
  int claimCount = 0;
  int unsubscribeCount = 0;
  void Function()? _onPrintJobChanged;

  @override
  Future<List<PrintAgentJob>> claimJobs(
    String storeId, {
    int limit = 10,
  }) async {
    claimedStoreId = storeId;
    claimCount++;
    return jobs.take(limit).toList();
  }

  @override
  Future<void> completeJob(
    String jobId, {
    required bool ok,
    String? error,
  }) async {
    completed.add(_Completion(jobId: jobId, ok: ok, error: error));
  }

  @override
  Future<PrintDestination?> loadDestination(String destinationId) async {
    return destinations[destinationId];
  }

  @override
  Future<void> subscribeToJobs(
    String storeId,
    void Function() onChanged,
  ) async {
    subscribedStoreId = storeId;
    _onPrintJobChanged = onChanged;
  }

  @override
  Future<void> unsubscribeFromJobs() async {
    if (_onPrintJobChanged != null) {
      unsubscribeCount++;
    }
    _onPrintJobChanged = null;
  }

  void triggerPrintJobChange() {
    _onPrintJobChanged?.call();
  }
}

class _FakePrinterService implements PrinterService {
  _FakePrinterService(this.result);

  final PrintResult result;
  final prints = <_PrintCall>[];

  @override
  bool get isSupported => true;

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    prints.add(_PrintCall(ip: ip, port: port, bytes: bytes));
    return result;
  }

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async {
    return true;
  }
}

class _UnsupportedPrinterService implements PrinterService {
  @override
  bool get isSupported => false;

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    return PrintResult.notSupported;
  }

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async {
    return false;
  }
}

class _PrintCall {
  const _PrintCall({required this.ip, required this.port, required this.bytes});

  final String ip;
  final int port;
  final List<int> bytes;
}

class _Completion {
  const _Completion({required this.jobId, required this.ok, this.error});

  final String jobId;
  final bool ok;
  final String? error;

  @override
  bool operator ==(Object other) {
    return other is _Completion &&
        other.jobId == jobId &&
        other.ok == ok &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(jobId, ok, error);
}
