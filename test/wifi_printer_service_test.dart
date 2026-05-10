import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/core/hardware/wifi_printer_service.dart';

void main() {
  group('WifiPrinterService', () {
    test('testConnection returns true when printer socket accepts connections', () async {
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
    });

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

    test('printReceipt reports connection failure for unreachable endpoint', () async {
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
    });
  });
}
