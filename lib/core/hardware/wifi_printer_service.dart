import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'printer_service.dart';

class WifiPrinterService implements PrinterService {
  static const connectionTimeout = Duration(seconds: 5);
  static const printFlushTimeout = Duration(seconds: 5);
  static const socketCloseTimeout = Duration(seconds: 2);

  @override
  bool get isSupported => !kIsWeb;

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async {
    if (kIsWeb) {
      return false;
    }
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    if (kIsWeb) {
      return PrintResult.notSupported;
    }
    if (bytes.isEmpty) {
      return PrintResult.printFailed;
    }
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: connectionTimeout);
      socket.add(bytes);
      await socket.flush().timeout(printFlushTimeout);
      await socket.close().timeout(socketCloseTimeout);
      return PrintResult.success;
    } on SocketException {
      return PrintResult.connectionFailed;
    } on TimeoutException {
      return PrintResult.connectionFailed;
    } catch (_) {
      return PrintResult.printFailed;
    } finally {
      socket?.destroy();
    }
  }
}

PrinterService createPrinterService() => WifiPrinterService();
