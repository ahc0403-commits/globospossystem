import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/hardware/printer_service.dart';
import '../../core/hardware/wifi_printer_service.dart';

class PrinterState {
  const PrinterState({
    this.printerIp = '',
    this.printerPort = '9100',
    this.isTesting = false,
    this.lastTestResult,
    this.isPrinting = false,
    this.error,
  });

  final String printerIp;
  final String printerPort;
  final bool isTesting;
  final bool? lastTestResult;
  final bool isPrinting;
  final String? error;

  PrinterState copyWith({
    String? printerIp,
    String? printerPort,
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
  PrinterNotifier({PrinterService? service})
    : _service = service ?? createPrinterService(),
      super(const PrinterState()) {
    _loadSavedSettings();
  }

  final PrinterService _service;
  static const _ipKey = 'printer_ip';
  static const _portKey = 'printer_port';

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_ipKey) ?? '';
    final port = prefs.getString(_portKey) ?? '9100';
    state = state.copyWith(printerIp: ip, printerPort: port);
  }

  Future<void> setIp(String ip) async {
    final normalized = ip.trim();
    state = state.copyWith(
      printerIp: normalized,
      clearTestResult: true,
      clearError: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ipKey, normalized);
  }

  Future<void> setPort(String port) async {
    final normalized = port.trim();
    state = state.copyWith(
      printerPort: normalized,
      clearTestResult: true,
      clearError: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_portKey, normalized);
  }

  int? _validatedPort(String value) {
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  Future<void> testConnection({String? ip, String? port}) async {
    final targetIp = (ip ?? state.printerIp).trim();
    final targetPortText = (port ?? state.printerPort).trim();
    state = state.copyWith(
      printerIp: targetIp,
      printerPort: targetPortText,
      clearError: true,
      clearTestResult: true,
    );
    if (targetIp.isEmpty) {
      state = state.copyWith(error: 'Enter the IP address first.');
      return;
    }
    final targetPort = _validatedPort(targetPortText);
    if (targetPort == null) {
      state = state.copyWith(error: 'Enter a valid printer port (1-65535).');
      return;
    }

    state = state.copyWith(
      isTesting: true,
      clearError: true,
      clearTestResult: true,
    );
    final ok = await _service.testConnection(targetIp, port: targetPort);
    state = state.copyWith(isTesting: false, lastTestResult: ok);
  }

  Future<PrintResult> print(List<int> bytes) async {
    if (state.printerIp.isEmpty) {
      return PrintResult.connectionFailed;
    }
    final port = _validatedPort(state.printerPort);
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
