import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'printer_service.dart';

class WifiPrinterService implements PrinterService {
  static const connectionTimeout = Duration(seconds: 5);
  static const sourceAddressTimeout = Duration(seconds: 2);
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
      final socket = await _connectToPrinter(
        ip,
        port,
        fallbackTimeout: const Duration(seconds: 3),
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
      socket = await _connectToPrinter(
        ip,
        port,
        fallbackTimeout: connectionTimeout,
      );
      socket.add(bytes);
      await socket.flush().timeout(printFlushTimeout);
      await socket.close().timeout(socketCloseTimeout);
      return PrintResult.success;
    } on SocketException catch (error) {
      return switch (error.osError?.errorCode) {
        10061 || 61 || 111 => PrintResult.connectionRefused,
        10060 || 60 || 110 => PrintResult.connectionTimeout,
        10051 ||
        10065 ||
        51 ||
        65 ||
        101 ||
        113 => PrintResult.networkUnreachable,
        _ => PrintResult.connectionFailed,
      };
    } on TimeoutException {
      return PrintResult.connectionTimeout;
    } catch (_) {
      return PrintResult.printFailed;
    } finally {
      socket?.destroy();
    }
  }

  Future<Socket> _connectToPrinter(
    String ip,
    int port, {
    required Duration fallbackTimeout,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (final sourceAddress in await _printerSourceAddresses(ip)) {
      try {
        return await Socket.connect(
          ip,
          port,
          sourceAddress: sourceAddress,
          timeout: sourceAddressTimeout,
        );
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }

    try {
      return await Socket.connect(ip, port, timeout: fallbackTimeout);
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
    }

    Error.throwWithStackTrace(lastError, lastStackTrace);
  }

  Future<List<String>> _printerSourceAddresses(String printerIp) async {
    final targetAddress = InternetAddress.tryParse(printerIp);
    if (targetAddress == null || targetAddress.isLoopback) {
      return const <String>[];
    }
    final targetParts = printerIp.split('.');
    if (targetParts.length != 4) return const <String>[];

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: true,
      );
      final candidates = <({String address, int priority})>[];
      for (final interface in interfaces) {
        final interfaceName = interface.name.toLowerCase();
        final isWireless =
            interfaceName.contains('wi-fi') ||
            interfaceName.contains('wifi') ||
            interfaceName.contains('wireless') ||
            interfaceName.contains('wlan');
        final isWired =
            interfaceName.contains('ethernet') ||
            interfaceName.contains('이더넷') ||
            interfaceName.contains('local area connection') ||
            interfaceName == 'lan';
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
            continue;
          }
          final sourceParts = address.address.split('.');
          if (sourceParts.length != 4) continue;
          final samePrinterSubnet =
              sourceParts[0] == targetParts[0] &&
              sourceParts[1] == targetParts[1] &&
              sourceParts[2] == targetParts[2];
          final priority =
              (samePrinterSubnet ? 0 : 10) +
              (isWired ? 0 : (isWireless ? 2 : 1));
          candidates.add((address: address.address, priority: priority));
        }
      }
      candidates.sort((a, b) => a.priority.compareTo(b.priority));
      return candidates.map((candidate) => candidate.address).toSet().toList();
    } catch (_) {
      return const <String>[];
    }
  }
}

PrinterService createPrinterService() => WifiPrinterService();
