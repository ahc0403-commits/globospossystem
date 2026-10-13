import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'printer_service.dart';
import 'printer_diagnostics.dart';

typedef PrinterSocketConnector =
    Future<Socket> Function(
      String ip,
      int port,
      String? sourceAddress,
      Duration timeout,
    );

class WifiPrinterService
    implements PrinterService, UsbPrinterService, DiagnosticPrinterService {
  WifiPrinterService({
    PrinterSocketConnector? socketConnector,
    Future<List<String>> Function(String)? sourceAddresses,
  }) : _socketConnector = socketConnector ?? _openSocket,
       _sourceAddresses = sourceAddresses;

  final PrinterSocketConnector _socketConnector;
  final Future<List<String>> Function(String)? _sourceAddresses;

  static Future<Socket> _openSocket(
    String ip,
    int port,
    String? sourceAddress,
    Duration timeout,
  ) => Socket.connect(ip, port, sourceAddress: sourceAddress, timeout: timeout);
  static const _usbPrinterChannel = MethodChannel('globos/usb_printer');
  static const connectionTimeout = Duration(seconds: 5);
  static const sourceAddressTimeout = Duration(seconds: 2);
  static const printFlushTimeout = Duration(seconds: 5);
  static const socketCloseTimeout = Duration(seconds: 2);

  @override
  bool get isSupported => !kIsWeb;

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async =>
      (await checkNetworkPrinter(ip, port: port)).result == PrintResult.success;

  @override
  Future<PrinterOperationStatus> checkNetworkPrinter(
    String ip, {
    int port = 9100,
  }) async {
    if (kIsWeb) return const PrinterOperationStatus(PrintResult.notSupported);
    Socket? socket;
    try {
      socket = await _connectToPrinter(
        ip.trim(),
        port,
        fallbackTimeout: const Duration(seconds: 3),
      );
      await socket.close().timeout(socketCloseTimeout);
      return const PrinterOperationStatus(PrintResult.success);
    } catch (error) {
      return _failure(error);
    } finally {
      socket?.destroy();
    }
  }

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async => (await printNetworkPrinter(ip, bytes, port: port)).result;

  @override
  Future<PrinterOperationStatus> printNetworkPrinter(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    if (kIsWeb) return const PrinterOperationStatus(PrintResult.notSupported);
    if (bytes.isEmpty) {
      return const PrinterOperationStatus(PrintResult.printFailed);
    }
    Socket? socket;
    var mayHavePrinted = false;
    try {
      socket = await _connectToPrinter(
        ip.trim(),
        port,
        fallbackTimeout: connectionTimeout,
      );
      mayHavePrinted = true;
      socket.add(bytes);
      await socket.flush().timeout(printFlushTimeout);
      await socket.close().timeout(socketCloseTimeout);
      return const PrinterOperationStatus(PrintResult.success);
    } catch (error) {
      return _failure(error, mayHavePrinted: mayHavePrinted);
    } finally {
      socket?.destroy();
    }
  }

  @override
  Future<PrintResult> printUsbReceipt(
    String printerName,
    List<int> bytes,
  ) async => (await printWindowsPrinter(printerName, bytes)).result;

  @override
  Future<PrinterOperationStatus> checkUsbPrinter(String printerName) =>
      _windowsPrinterOperation('testConnection', printerName);

  @override
  Future<PrinterOperationStatus> printWindowsPrinter(
    String printerName,
    List<int> bytes,
  ) => _windowsPrinterOperation('printRaw', printerName, bytes: bytes);

  Future<PrinterOperationStatus> _windowsPrinterOperation(
    String method,
    String printerName, {
    List<int>? bytes,
  }) async {
    if (!Platform.isWindows) {
      return const PrinterOperationStatus(PrintResult.notSupported);
    }
    if (printerName.trim().isEmpty || (bytes != null && bytes.isEmpty)) {
      return const PrinterOperationStatus(
        PrintResult.connectionFailed,
        errorCode: 'PRINTER_CONFIGURATION_INVALID',
      );
    }
    try {
      final ok = await _usbPrinterChannel.invokeMethod<bool>(method, {
        'printerName': printerName.trim(),
        if (bytes != null) 'bytes': Uint8List.fromList(bytes),
      });
      return PrinterOperationStatus(
        ok == true ? PrintResult.success : PrintResult.printFailed,
        mayHavePrinted: bytes != null,
      );
    } on PlatformException catch (error) {
      return PrinterOperationStatus(
        PrintResult.printFailed,
        errorCode: error.code,
        mayHavePrinted:
            bytes != null && error.code == 'USB_PRINTER_WRITE_FAILED',
      );
    } catch (_) {
      return PrinterOperationStatus(
        PrintResult.printFailed,
        errorCode: 'WINDOWS_PRINTER_UNAVAILABLE',
        mayHavePrinted: bytes != null,
      );
    }
  }

  PrinterOperationStatus _failure(Object error, {bool mayHavePrinted = false}) {
    final result = switch (error) {
      SocketException e => switch (e.osError?.errorCode) {
        10061 || 61 || 111 => PrintResult.connectionRefused,
        10060 || 60 || 110 => PrintResult.connectionTimeout,
        10051 ||
        10065 ||
        51 ||
        65 ||
        101 ||
        113 => PrintResult.networkUnreachable,
        _ => PrintResult.connectionFailed,
      },
      TimeoutException() => PrintResult.connectionTimeout,
      ArgumentError() => PrintResult.connectionFailed,
      _ => PrintResult.printFailed,
    };
    return PrinterOperationStatus(
      result,
      errorCode: switch (error) {
        SocketException e when e.osError != null =>
          'SOCKET_${e.osError!.errorCode}',
        ArgumentError() => 'PRINTER_CONFIGURATION_INVALID',
        _ => null,
      },
      mayHavePrinted: mayHavePrinted,
    );
  }

  Future<Socket> _connectToPrinter(
    String ip,
    int port, {
    required Duration fallbackTimeout,
  }) async {
    if (InternetAddress.tryParse(ip) == null || port <= 0 || port > 65535) {
      throw ArgumentError('PRINTER_CONFIGURATION_INVALID');
    }
    // Let Windows select its routed interface first. A VPN, virtual adapter or
    // unrelated NIC must not delay a working default route to the printer.
    try {
      return await _socketConnector(ip, port, null, fallbackTimeout);
    } catch (defaultError, defaultStack) {
      final addresses =
          await (_sourceAddresses?.call(ip) ?? _printerSourceAddresses(ip))
              .timeout(const Duration(seconds: 1), onTimeout: () => const []);
      for (final sourceAddress in addresses.toSet().take(3)) {
        try {
          return await _socketConnector(
            ip,
            port,
            sourceAddress,
            sourceAddressTimeout,
          );
        } catch (_) {
          // Connection failed before bytes were sent; bounded fallback is safe.
        }
      }
      Error.throwWithStackTrace(defaultError, defaultStack);
    }
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
