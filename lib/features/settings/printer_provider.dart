import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/hardware/printer_service.dart';
import '../../core/hardware/wifi_printer_service.dart';

class PrinterState {
  const PrinterState({
    this.printerIp = '',
    this.isTesting = false,
    this.lastTestResult,
    this.isPrinting = false,
    this.error,
  });

  final String printerIp;
  final bool isTesting;
  final bool? lastTestResult;
  final bool isPrinting;
  final String? error;

  PrinterState copyWith({
    String? printerIp,
    bool? isTesting,
    bool? lastTestResult,
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
      isPrinting: isPrinting ?? this.isPrinting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PrinterNotifier extends StateNotifier<PrinterState> {
  PrinterNotifier() : super(const PrinterState()) {
    _loadSavedIp();
  }

  final _service = createPrinterService();
  static const _ipKey = 'printer_ip';

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_ipKey) ?? '';
    state = state.copyWith(printerIp: ip);
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

  Future<void> testConnection() async {
    if (state.printerIp.isEmpty) {
      state = state.copyWith(error: 'IP 주소를 먼저 입력해주세요.');
      return;
    }

    state = state.copyWith(
      isTesting: true,
      clearError: true,
      clearTestResult: true,
    );
    final ok = await _service.testConnection(state.printerIp);
    state = state.copyWith(isTesting: false, lastTestResult: ok);
  }

  Future<PrintResult> print(List<int> bytes) async {
    if (state.printerIp.isEmpty) {
      return PrintResult.connectionFailed;
    }
    state = state.copyWith(isPrinting: true, clearError: true);
    final result = await _service.printReceipt(state.printerIp, bytes);
    state = state.copyWith(isPrinting: false);
    if (result == PrintResult.connectionFailed) {
      state = state.copyWith(error: '프린터 연결 실패. IP를 확인해주세요.');
    } else if (result == PrintResult.printFailed) {
      state = state.copyWith(error: '영수증 출력 실패. 프린터 상태를 확인해주세요.');
    } else if (result == PrintResult.notSupported) {
      state = state.copyWith(error: '프린터는 앱에서만 지원됩니다.');
    }
    return result;
  }
}

final printerProvider = StateNotifierProvider<PrinterNotifier, PrinterState>(
  (ref) => PrinterNotifier(),
);
