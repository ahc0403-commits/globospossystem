import 'dart:io';

import 'package:flutter/foundation.dart';

import 'printer_service.dart';

class WifiPrinterService implements PrinterService {
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
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      return PrintResult.success;
    } on SocketException {
      return PrintResult.connectionFailed;
    } catch (_) {
      return PrintResult.printFailed;
    }
  }
}

PrinterService createPrinterService() => WifiPrinterService();
