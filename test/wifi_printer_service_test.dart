import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/network_capability_service.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/core/hardware/wifi_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('operational printer alert is five 450ms beeps', () {
    expect(ReceiptBuilder.internalBuzzerAlertBytes, <int>[0x1B, 0x42, 5, 9]);
  });

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

        expect(
          result,
          anyOf(PrintResult.connectionRefused, PrintResult.connectionFailed),
        );
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
            purpose: 'tray',
          ),
        },
      );
      final printer = _FakePrinterService(PrintResult.success);
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: _availableNetwork,
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      expect(backend.claimedStoreId, 'store-1');
      expect(backend.completed, [const _Completion(jobId: 'job-1', ok: true)]);
      expect(printer.prints.single.ip, '192.168.1.50');
      expect(printer.prints.single.port, 9100);
      expect(
        String.fromCharCodes(printer.prints.single.bytes),
        contains('KHAY'),
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
        networkCapabilityService: _availableNetwork,
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.connectionFailed);
      expect(backend.completed, [
        const _Completion(
          jobId: 'job-2',
          ok: false,
          error:
              'ALL_ENDPOINTS_FAILED:wireless@192.168.1.51:9101=connectionFailed',
        ),
      ]);
    });

    test(
      'wired PC can fall back from wired to wireless printer endpoint',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: [
            _job(id: 'job-wired', destinationId: 'dest', ticketType: 'kitchen'),
          ],
          destinations: const {
            'dest': PrintDestination(
              id: 'dest',
              name: 'Kitchen',
              ip: '192.168.1.252',
              port: 9100,
              endpoints: [
                PrinterEndpoint(
                  id: 'wired',
                  type: PrinterEndpointType.wired,
                  ip: '192.168.1.120',
                  port: 9100,
                  priority: 10,
                  isActive: true,
                ),
                PrinterEndpoint(
                  id: 'wireless',
                  type: PrinterEndpointType.wireless,
                  ip: '192.168.1.252',
                  port: 9100,
                  priority: 20,
                  isActive: true,
                ),
              ],
            ),
          },
        );
        final printer = _EndpointAwareFakePrinterService({
          '192.168.1.120': PrintResult.connectionRefused,
          '192.168.1.252': PrintResult.success,
        });
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
          networkCapabilityService: const _FakeNetworkCapabilityService(
            wiredConnected: true,
            wirelessConnected: false,
          ),
        );

        final results = await agent.processOnce('store-1');

        expect(results.single.result, PrintResult.success);
        expect(printer.prints.map((call) => call.ip), [
          '192.168.1.120',
          '192.168.1.252',
        ]);
        expect(_hasBuzzerAlert(printer.prints[1].bytes), isTrue);
      },
    );

    test(
      'wireless-connected PC tries configured endpoints by priority',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: [
            _job(
              id: 'job-wireless',
              destinationId: 'dest',
              ticketType: 'kitchen',
            ),
          ],
          destinations: const {
            'dest': PrintDestination(
              id: 'dest',
              name: 'Kitchen',
              ip: '192.168.1.252',
              port: 9100,
              endpoints: [
                PrinterEndpoint(
                  id: 'wired',
                  type: PrinterEndpointType.wired,
                  ip: '192.168.1.120',
                  port: 9100,
                  priority: 10,
                  isActive: true,
                ),
                PrinterEndpoint(
                  id: 'wireless',
                  type: PrinterEndpointType.wireless,
                  ip: '192.168.1.252',
                  port: 9100,
                  priority: 20,
                  isActive: true,
                ),
              ],
            ),
          },
        );
        final printer = _EndpointAwareFakePrinterService({
          '192.168.1.120': PrintResult.success,
          '192.168.1.252': PrintResult.success,
        });
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
          networkCapabilityService: const _FakeNetworkCapabilityService(
            wiredConnected: false,
            wirelessConnected: true,
          ),
        );

        final results = await agent.processOnce('store-1');

        expect(results.single.result, PrintResult.success);
        expect(printer.prints, hasLength(1));
        expect(printer.prints.single.ip, '192.168.1.120');
      },
    );

    test('wireless-connected PC can reach a wired-only printer IP', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          _job(id: 'job-blocked', destinationId: 'dest', ticketType: 'kitchen'),
        ],
        destinations: const {
          'dest': PrintDestination(
            id: 'dest',
            name: 'Kitchen',
            ip: '192.168.1.120',
            port: 9100,
            endpoints: [
              PrinterEndpoint(
                id: 'wired',
                type: PrinterEndpointType.wired,
                ip: '192.168.1.120',
                port: 9100,
                priority: 10,
                isActive: true,
              ),
            ],
          ),
        },
      );
      final printer = _EndpointAwareFakePrinterService({
        '192.168.1.120': PrintResult.success,
      });
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: const _FakeNetworkCapabilityService(
          wiredConnected: false,
          wirelessConnected: true,
        ),
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      expect(printer.prints.single.ip, '192.168.1.120');
      expect(backend.completed.single.ok, isTrue);
    });

    test(
      'PC with no active network does not try any printer endpoint',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: [
            _job(
              id: 'job-offline',
              destinationId: 'dest',
              ticketType: 'kitchen',
            ),
          ],
          destinations: const {
            'dest': PrintDestination(
              id: 'dest',
              name: 'Kitchen',
              ip: '192.168.1.252',
              port: 9100,
            ),
          },
        );
        final printer = _EndpointAwareFakePrinterService({
          '192.168.1.252': PrintResult.success,
        });
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
          networkCapabilityService: const _FakeNetworkCapabilityService(
            wiredConnected: false,
            wirelessConnected: false,
          ),
        );

        final results = await agent.processOnce('store-1');

        expect(results.single.result, PrintResult.networkUnavailable);
        expect(printer.prints, isEmpty);
        expect(backend.completed.single.error, 'NETWORK_UNAVAILABLE');
      },
    );

    test('USB printer works without an active network connection', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          _job(id: 'job-usb', destinationId: 'dest', ticketType: 'kitchen'),
        ],
        destinations: const {
          'dest': PrintDestination(
            id: 'dest',
            name: 'USB Kitchen',
            ip: '127.0.0.1',
            port: 9100,
            endpoints: [
              PrinterEndpoint(
                id: 'usb',
                type: PrinterEndpointType.usb,
                ip: '',
                deviceName: 'EPSON TM-T88VII Receipt',
                port: 9100,
                priority: 5,
                isActive: true,
              ),
            ],
          ),
        },
      );
      final printer = _UsbAwareFakePrinterService();
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: const _FakeNetworkCapabilityService(
          wiredConnected: false,
          wirelessConnected: false,
        ),
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      expect(printer.usbPrinterNames, ['EPSON TM-T88VII Receipt']);
      expect(backend.completed.single.ok, isTrue);
    });

    test('partial multi-copy print never switches printer endpoints', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          _job(id: 'job-partial', destinationId: 'dest', ticketType: 'floor'),
        ],
        destinations: const {
          'dest': PrintDestination(
            id: 'dest',
            name: 'Floor',
            ip: '192.168.1.252',
            port: 9100,
            endpoints: [
              PrinterEndpoint(
                id: 'wired',
                type: PrinterEndpointType.wired,
                ip: '192.168.1.120',
                port: 9100,
                priority: 10,
                isActive: true,
              ),
              PrinterEndpoint(
                id: 'wireless',
                type: PrinterEndpointType.wireless,
                ip: '192.168.1.252',
                port: 9100,
                priority: 20,
                isActive: true,
              ),
            ],
          ),
        },
      );
      final printer = _SequencedFakePrinterService({
        '192.168.1.120': [PrintResult.success, PrintResult.connectionFailed],
        '192.168.1.252': [PrintResult.success],
      });
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: const _FakeNetworkCapabilityService(
          wiredConnected: true,
          wirelessConnected: false,
        ),
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.connectionFailed);
      expect(printer.prints.map((call) => call.ip), [
        '192.168.1.120',
        '192.168.1.120',
      ]);
      expect(
        backend.completed.single.error,
        'PARTIAL_PRINT:wired@192.168.1.120:9100=connectionFailed',
      );
    });

    test('processOnce prints two complete copies for floor jobs', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          _job(
            id: 'job-floor-copies',
            destinationId: 'dest-floor',
            ticketType: 'floor',
          ),
        ],
        destinations: const {
          'dest-floor': PrintDestination(
            id: 'dest-floor',
            name: '2F',
            ip: '192.168.1.53',
            port: 9100,
            purpose: 'floor',
          ),
        },
      );
      final printer = _FakePrinterService(PrintResult.success);
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: _availableNetwork,
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      expect(printer.prints, hasLength(2));
      expect(printer.prints[0].bytes, printer.prints[1].bytes);
      expect(_hasBuzzerAlert(printer.prints[0].bytes), isTrue);
      expect(
        String.fromCharCodes(printer.prints[0].bytes),
        allOf(contains('PHIEU TANG'), contains('1F / T07')),
      );
    });

    for (final printedReason in ['initial', 'reprint']) {
      test(
        'processOnce prints one alerted kitchen copy for $printedReason',
        () async {
          final backend = _FakePrintJobBackend(
            jobs: [
              _job(
                id: 'job-kitchen-$printedReason',
                destinationId: 'dest-kitchen',
                ticketType: 'kitchen',
                printedReason: printedReason,
              ),
            ],
            destinations: const {
              'dest-kitchen': PrintDestination(
                id: 'dest-kitchen',
                name: 'Kitchen',
                ip: '192.168.1.55',
                port: 9100,
                purpose: 'kitchen',
              ),
            },
          );
          final printer = _FakePrinterService(PrintResult.success);
          final agent = PrintJobAgentService(
            backend: backend,
            printerService: printer,
            networkCapabilityService: _availableNetwork,
          );

          final results = await agent.processOnce('store-1');

          expect(results.single.result, PrintResult.success);
          expect(printer.prints, hasLength(1));
          expect(_hasBuzzerAlert(printer.prints[0].bytes), isTrue);
          expect(
            printer.prints[0].bytes.take(4),
            ReceiptBuilder.internalBuzzerAlertBytes,
          );
        },
      );
    }

    test('processOnce prints one kitchen and one fallback tray copy', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          _job(
            id: 'job-added-kitchen-copies',
            destinationId: 'dest-kitchen',
            ticketType: 'kitchen',
            printedReason: 'added_items',
          ),
          _job(
            id: 'job-added-tray-copy',
            destinationId: 'dest-kitchen',
            ticketType: 'tray',
            printedReason: 'added_items',
          ),
        ],
        destinations: const {
          'dest-kitchen': PrintDestination(
            id: 'dest-kitchen',
            name: 'Kitchen',
            ip: '192.168.1.55',
            port: 9100,
            purpose: 'kitchen',
          ),
        },
      );
      final printer = _FakePrinterService(PrintResult.success);
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: _availableNetwork,
      );

      final results = await agent.processOnce('store-1');

      expect(results, hasLength(2));
      expect(
        results.map((result) => result.result),
        everyElement(PrintResult.success),
      );
      expect(printer.prints, hasLength(2));
      expect(_hasBuzzerAlert(printer.prints[0].bytes), isTrue);
      expect(_hasBuzzerAlert(printer.prints[1].bytes), isTrue);
      expect(
        String.fromCharCodes(printer.prints[0].bytes),
        allOf(contains('PHIEU BEP'), contains('MON THEM')),
      );
      expect(String.fromCharCodes(printer.prints[1].bytes), contains('KHAY'));
    });

    test(
      'processOnce prints two complete copies for floor confirmation jobs',
      () async {
        final backend = _FakePrintJobBackend(
          jobs: [
            _job(
              id: 'job-confirmation-copies',
              destinationId: 'dest-floor-confirmation',
              ticketType: 'confirmation',
              unitPrice: 12000,
            ),
          ],
          destinations: const {
            'dest-floor-confirmation': PrintDestination(
              id: 'dest-floor-confirmation',
              name: '3F',
              ip: '192.168.1.54',
              port: 9100,
              purpose: 'floor',
            ),
          },
        );
        final printer = _FakePrinterService(PrintResult.success);
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
          networkCapabilityService: _availableNetwork,
        );

        final results = await agent.processOnce('store-1');

        expect(results.single.result, PrintResult.success);
        expect(printer.prints, hasLength(2));
        expect(printer.prints[0].bytes, printer.prints[1].bytes);
        expect(_hasBuzzerAlert(printer.prints[0].bytes), isTrue);
        expect(
          String.fromCharCodes(printer.prints[0].bytes),
          allOf(
            contains('XAC NHAN DON'),
            contains('1 x 12,000 VND = 12,000 VND'),
            contains('Tong cong'),
          ),
        );
      },
    );

    test('processOnce renders receipt jobs as payment receipts', () async {
      final backend = _FakePrintJobBackend(
        jobs: [
          PrintAgentJob.fromJson({
            'id': 'job-receipt',
            'destination_id': 'dest-receipt',
            'payload': {
              'ticket': 'receipt',
              'restaurant_name': 'GLOBOS PILOT',
              'table_number': 'T07',
              'total_amount': 50000,
              'payment_method': 'CASH',
              'at': '2026-07-10T12:00:00+07:00',
              'items': [
                {
                  'label': 'Pho Bo',
                  'quantity': 1,
                  'unit_price': 50000,
                  'is_service_item': false,
                },
              ],
            },
          }),
        ],
        destinations: const {
          'dest-receipt': PrintDestination(
            id: 'dest-receipt',
            name: 'Cashier',
            ip: '192.168.1.52',
            port: 9100,
            purpose: 'receipt',
          ),
        },
      );
      final printer = _FakePrinterService(PrintResult.success);
      final agent = PrintJobAgentService(
        backend: backend,
        printerService: printer,
        networkCapabilityService: _availableNetwork,
      );

      final results = await agent.processOnce('store-1');

      expect(results.single.result, PrintResult.success);
      final output = String.fromCharCodes(printer.prints.single.bytes);
      expect(output, contains('GLOBOS PILOT'));
      expect(output, contains('PHIEU THANH TOAN'));
      expect(output, contains('TONG CONG'));
      expect(output, isNot(contains('PHIEU BEP')));
      expect(_hasBuzzerAlert(printer.prints.single.bytes), isFalse);
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
              purpose: 'floor',
            ),
          },
        );
        final printer = _FakePrinterService(PrintResult.success);
        final agent = PrintJobAgentService(
          backend: backend,
          printerService: printer,
          networkCapabilityService: _availableNetwork,
        );

        final result = await agent.testPrintDestination('dest-test');

        expect(result, PrintResult.success);
        expect(printer.prints, hasLength(2));
        expect(
          printer.prints.map((call) => call.ip),
          everyElement('192.168.1.77'),
        );
        expect(printer.prints.map((call) => call.port), everyElement(9102));
        expect(
          String.fromCharCodes(printer.prints.first.bytes),
          contains('TEST'),
        );
        expect(_hasBuzzerAlert(printer.prints.first.bytes), isTrue);
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
          networkCapabilityService: _availableNetwork,
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

const _availableNetwork = _FakeNetworkCapabilityService(
  wiredConnected: true,
  wirelessConnected: true,
);

PrintAgentJob _job({
  required String id,
  required String destinationId,
  required String ticketType,
  double? unitPrice,
  String printedReason = 'initial',
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
      printedReason: printedReason,
      printedAt: '2026-07-06T12:00:00+07:00',
      items: [
        PrintTicketItem(label: 'Pho Bo', quantity: 1, unitPrice: unitPrice),
      ],
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

class _EndpointAwareFakePrinterService implements PrinterService {
  _EndpointAwareFakePrinterService(this.resultsByIp);

  final Map<String, PrintResult> resultsByIp;
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
    return resultsByIp[ip] ?? PrintResult.connectionFailed;
  }

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async =>
      resultsByIp[ip] == PrintResult.success;
}

class _SequencedFakePrinterService implements PrinterService {
  _SequencedFakePrinterService(Map<String, List<PrintResult>> resultsByIp)
    : resultsByIp = resultsByIp.map(
        (ip, results) => MapEntry(ip, List<PrintResult>.of(results)),
      );

  final Map<String, List<PrintResult>> resultsByIp;
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
    final results = resultsByIp[ip];
    if (results == null || results.isEmpty) {
      return PrintResult.connectionFailed;
    }
    return results.removeAt(0);
  }

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async => false;
}

class _FakeNetworkCapabilityService implements NetworkCapabilityService {
  const _FakeNetworkCapabilityService({
    required this.wiredConnected,
    required this.wirelessConnected,
  });

  final bool wiredConnected;
  final bool wirelessConnected;

  @override
  Future<NetworkCapabilities> loadCapabilities() async => NetworkCapabilities(
    wiredConnected: wiredConnected,
    wirelessConnected: wirelessConnected,
  );
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

class _UsbAwareFakePrinterService implements PrinterService, UsbPrinterService {
  final usbPrinterNames = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async => PrintResult.connectionFailed;

  @override
  Future<PrintResult> printUsbReceipt(
    String printerName,
    List<int> bytes,
  ) async {
    usbPrinterNames.add(printerName);
    return PrintResult.success;
  }

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async => false;
}

bool _hasBuzzerAlert(List<int> bytes) {
  final alert = ReceiptBuilder.internalBuzzerAlertBytes;
  if (bytes.length < alert.length) return false;
  for (var offset = 0; offset <= bytes.length - alert.length; offset++) {
    var matches = true;
    for (var index = 0; index < alert.length; index++) {
      if (bytes[offset + index] != alert[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
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
