import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/hardware/printer_service.dart';
import '../../core/hardware/printer_diagnostics.dart';
import '../../core/hardware/wifi_printer_service.dart';

class PrinterState {
  const PrinterState({
    this.printerIp = '',
    this.isTesting = false,
    this.lastTestResult,
    this.diagnostic,
    this.isPrinting = false,
    this.error,
  });

  final String printerIp;
  final bool isTesting;
  final bool? lastTestResult;
  final PrinterTestReport? diagnostic;
  final bool isPrinting;
  final String? error;

  PrinterState copyWith({
    String? printerIp,
    bool? isTesting,
    bool? lastTestResult,
    PrinterTestReport? diagnostic,
    bool? isPrinting,
    String? error,
    bool clearError = false,
    bool clearTestResult = false,
  }) {
    return PrinterState(
      printerIp: printerIp ?? this.printerIp,
      isTesting: isTesting ?? this.isTesting,
      lastTestResult: clearTestResult
          ? null
          : (lastTestResult ?? this.lastTestResult),
      diagnostic: clearTestResult ? null : (diagnostic ?? this.diagnostic),
      isPrinting: isPrinting ?? this.isPrinting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PrinterNotifier extends StateNotifier<PrinterState> {
  PrinterNotifier({
    PrinterService? service,
    Future<SharedPreferences> Function()? preferences,
  }) : _service = service ?? createPrinterService(),
       _preferences = preferences ?? SharedPreferences.getInstance,
       super(const PrinterState()) {
    _loadSavedIp();
  }

  final PrinterService _service;
  final Future<SharedPreferences> Function() _preferences;
  static const _ipKey = 'printer_ip';
  int _ipRevision = 0;

  Future<void> _loadSavedIp() async {
    final revision = _ipRevision;
    final prefs = await _preferences();
    if (!mounted || revision != _ipRevision) return;
    final ip = prefs.getString(_ipKey) ?? '';
    state = state.copyWith(printerIp: ip);
  }

  Future<void> setIp(String ip) async {
    final normalized = ip.trim();
    final revision = ++_ipRevision;
    state = state.copyWith(
      printerIp: normalized,
      isTesting: false,
      clearTestResult: true,
      clearError: true,
    );
    final prefs = await _preferences();
    if (!mounted || revision != _ipRevision) return;
    await prefs.setString(_ipKey, normalized);
  }

  Future<void> testConnection({String? ip}) async {
    final targetIp = (ip ?? state.printerIp).trim();
    final revision = _ipRevision;
    if (targetIp.isEmpty) {
      state = state.copyWith(error: 'Enter the IP address first.');
      return;
    }

    state = state.copyWith(
      isTesting: true,
      clearError: true,
      clearTestResult: true,
    );
    final status = _service is DiagnosticPrinterService
        ? await (_service as DiagnosticPrinterService).checkNetworkPrinter(
            targetIp,
          )
        : PrinterOperationStatus(
            await _service.testConnection(targetIp)
                ? PrintResult.success
                : PrintResult.connectionFailed,
          );
    if (!mounted || revision != _ipRevision) return;
    state = state.copyWith(
      isTesting: false,
      lastTestResult: status.result == PrintResult.success,
      diagnostic: PrinterTestReport(
        result: status.result,
        attempts: [
          PrinterEndpointAttempt(
            type: 'network',
            address: '$targetIp:9100',
            status: status,
          ),
        ],
      ),
    );
  }

  Future<PrintResult> print(List<int> bytes) async {
    if (state.printerIp.isEmpty) {
      return PrintResult.connectionFailed;
    }
    state = state.copyWith(isPrinting: true, clearError: true);
    final targetIp = state.printerIp;
    final revision = _ipRevision;
    final status = _service is DiagnosticPrinterService
        ? await (_service as DiagnosticPrinterService).printNetworkPrinter(
            targetIp,
            bytes,
          )
        : PrinterOperationStatus(await _service.printReceipt(targetIp, bytes));
    final result = status.result;
    if (!mounted) return result;
    state = state.copyWith(
      isPrinting: false,
      diagnostic: revision == _ipRevision
          ? PrinterTestReport(
              result: result,
              attempts: [
                PrinterEndpointAttempt(
                  type: 'network',
                  address: '$targetIp:9100',
                  status: status,
                ),
              ],
            )
          : null,
    );
    if (revision != _ipRevision) return result;
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
