import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/hardware/printer_service.dart';
import '../../core/hardware/wifi_printer_service.dart';

enum PrinterConnectionType { lan, wifi }

class PrinterState {
  const PrinterState({
    this.printerIp = '',
    this.printerPort = '9100',
    this.connectionType = PrinterConnectionType.lan,
    this.isTesting = false,
    this.lastTestResult,
    this.isPrinting = false,
    this.error,
  });

  final String printerIp;
  final String printerPort;
  final PrinterConnectionType connectionType;
  final bool isTesting;
  final bool? lastTestResult;
  final bool isPrinting;
  final String? error;

  PrinterState copyWith({
    String? printerIp,
    String? printerPort,
    PrinterConnectionType? connectionType,
    bool? isTesting,
    bool? lastTestResult,
    bool? isPrinting,
    String? error,
    bool clearError = false,
    bool clearTestResult = false,
  }) {
    return PrinterState(
      printerIp: printerIp ?? this.printerIp,
      printerPort: printerPort ?? this.printerPort,
      connectionType: connectionType ?? this.connectionType,
      isTesting: isTesting ?? this.isTesting,
      lastTestResult: clearTestResult
          ? null
          : (lastTestResult ?? this.lastTestResult),
      isPrinting: isPrinting ?? this.isPrinting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PrinterNotifier extends StateNotifier<PrinterState> {
  PrinterNotifier() : super(const PrinterState()) {
    _loadSavedSettings();
  }

  final _service = createPrinterService();
  static const _ipKey = 'printer_ip';
  static const _portKey = 'printer_port';
  static const _connectionTypeKey = 'printer_connection_type';

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_ipKey) ?? '';
    final port = prefs.getString(_portKey) ?? '9100';
    final savedConnectionType = prefs.getString(_connectionTypeKey);
    final connectionType =
        savedConnectionType == PrinterConnectionType.wifi.name
        ? PrinterConnectionType.wifi
        : PrinterConnectionType.lan;
    state = state.copyWith(
      printerIp: ip,
      printerPort: port,
      connectionType: connectionType,
    );
  }

  Future<void> setIp(String ip) async {
    final normalized = ip.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ipKey, normalized);
    state = state.copyWith(
      printerIp: normalized,
      clearTestResult: true,
      clearError: true,
    );
  }

  Future<void> setPort(String port) async {
    final normalized = port.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_portKey, normalized);
    state = state.copyWith(
      printerPort: normalized,
      clearTestResult: true,
      clearError: true,
    );
  }

  Future<void> setConnectionType(PrinterConnectionType connectionType) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_connectionTypeKey, connectionType.name);
    state = state.copyWith(
      connectionType: connectionType,
      clearTestResult: true,
      clearError: true,
    );
  }

  int? _validatedPort() {
    final port = int.tryParse(state.printerPort);
    if (port == null || port < 1 || port > 65535) {
      return null;
    }
    return port;
  }

  Future<void> testConnection() async {
    if (state.printerIp.isEmpty) {
      state = state.copyWith(error: 'Enter the IP address first.');
      return;
    }
    final port = _validatedPort();
    if (port == null) {
      state = state.copyWith(error: 'Enter a valid printer port (1-65535).');
      return;
    }

    state = state.copyWith(
      isTesting: true,
      clearError: true,
      clearTestResult: true,
    );
    final ok = await _service.testConnection(state.printerIp, port: port);
    state = state.copyWith(isTesting: false, lastTestResult: ok);
  }

  Future<PrintResult> print(List<int> bytes) async {
    if (state.printerIp.isEmpty) {
      return PrintResult.connectionFailed;
    }
    final port = _validatedPort();
    if (port == null) {
      state = state.copyWith(error: 'Enter a valid printer port (1-65535).');
      return PrintResult.connectionFailed;
    }
    state = state.copyWith(isPrinting: true, clearError: true);
    final result = await _service.printReceipt(
      state.printerIp,
      bytes,
      port: port,
    );
    state = state.copyWith(isPrinting: false);
    if (result == PrintResult.connectionFailed) {
      state = state.copyWith(error: 'Printer connection failed. Check the IP.');
    } else if (result == PrintResult.printFailed) {
      state = state.copyWith(
        error: 'Receipt print failed. Check printer status.',
      );
    } else if (result == PrintResult.notSupported) {
      state = state.copyWith(error: 'Printer is only supported on the app.');
    }
    return result;
  }
}

final printerProvider = StateNotifierProvider<PrinterNotifier, PrinterState>(
  (ref) => PrinterNotifier(),
);
