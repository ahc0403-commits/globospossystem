import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'print_job_agent_service.dart';
import 'print_station_mode.dart';
import 'printer_service.dart';
import 'printer_diagnostics.dart';

enum PrintAgentStatus {
  disabled,
  starting,
  running,
  degraded,
  stopped,
  unsupported,
}

class PrintAgentState {
  const PrintAgentState({
    this.preferenceLoaded = false,
    this.mode,
    this.isChangingMode = false,
    this.enabled = false,
    this.status = PrintAgentStatus.stopped,
    this.activeStoreId,
    this.lastProcessed = 0,
    this.lastSuccessful = 0,
    this.lastError,
  });

  final bool preferenceLoaded;
  final PrintStationMode? mode;
  final bool isChangingMode;
  final bool enabled;
  final PrintAgentStatus status;
  final String? activeStoreId;
  final int lastProcessed;
  final int lastSuccessful;
  final String? lastError;

  bool get isRunning => status == PrintAgentStatus.running;

  PrintAgentState copyWith({
    bool? preferenceLoaded,
    PrintStationMode? mode,
    bool? isChangingMode,
    bool? enabled,
    PrintAgentStatus? status,
    String? activeStoreId,
    int? lastProcessed,
    int? lastSuccessful,
    String? lastError,
    bool clearStore = false,
    bool clearError = false,
  }) {
    return PrintAgentState(
      preferenceLoaded: preferenceLoaded ?? this.preferenceLoaded,
      mode: mode ?? this.mode,
      isChangingMode: isChangingMode ?? this.isChangingMode,
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      activeStoreId: clearStore ? null : (activeStoreId ?? this.activeStoreId),
      lastProcessed: lastProcessed ?? this.lastProcessed,
      lastSuccessful: lastSuccessful ?? this.lastSuccessful,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

abstract class PrintAgentPreferenceStore {
  Future<PrintStationMode?> readMode();
  Future<void> writeMode(PrintStationMode mode);
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool enabled);
}

class SharedPreferencesPrintAgentPreferenceStore
    implements PrintAgentPreferenceStore {
  static const preferenceKey = 'print_agent_enabled_v1';
  static const modeKey = 'print_station_mode_v1';

  @override
  Future<PrintStationMode?> readMode() async {
    final preferences = await SharedPreferences.getInstance();
    return PrintStationMode.fromValue(preferences.getString(modeKey));
  }

  @override
  Future<void> writeMode(PrintStationMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(modeKey, mode.name)) {
      throw StateError('PRINT_STATION_MODE_SAVE_FAILED');
    }
  }

  @override
  Future<bool> readEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(preferenceKey) ?? true;
  }

  @override
  Future<void> writeEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, enabled);
  }
}

class PrintAgentCoordinator extends StateNotifier<PrintAgentState> {
  PrintAgentCoordinator({
    required PrintAgentDriver agent,
    required PrintAgentPreferenceStore preferenceStore,
  }) : _agent = agent,
       _preferenceStore = preferenceStore,
       super(const PrintAgentState()) {
    unawaited(initialize());
  }

  final PrintAgentDriver _agent;
  final PrintAgentPreferenceStore _preferenceStore;
  Future<void> _transition = Future<void>.value();
  bool _authenticated = false;
  String? _role;
  String? _storeId;

  bool get isSupported => _agent.isSupported;

  static bool roleCanRun(String? role) => const {
    'cashier',
    'kitchen',
    'print_station',
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
  }.contains(role);

  Future<void> initialize() async {
    try {
      final enabled = await _preferenceStore.readEnabled();
      final mode = await _preferenceStore.readMode();
      if (!mounted) return;
      state = state.copyWith(
        preferenceLoaded: true,
        enabled: enabled,
        mode: mode,
      );
      await _scheduleReconcile();
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        preferenceLoaded: true,
        enabled: false,
        status: PrintAgentStatus.degraded,
        lastError: 'PRINT_AGENT_PREFERENCE_READ_FAILED',
      );
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await _preferenceStore.writeEnabled(enabled);
    state = state.copyWith(
      preferenceLoaded: true,
      enabled: enabled,
      clearError: true,
    );
    await _scheduleReconcile();
  }

  Future<bool> setMode(PrintStationMode mode) async {
    if (!state.preferenceLoaded || state.isChangingMode) return false;
    state = state.copyWith(
      isChangingMode: true,
      status: PrintAgentStatus.stopped,
      clearError: true,
    );
    try {
      // Stop and drain the old batch before changing its routing policy.
      await _agent.stopSafely();
      await _preferenceStore.writeMode(mode);
      if (!mounted) return false;
      state = state.copyWith(mode: mode, status: PrintAgentStatus.stopped);
      return true;
    } catch (_) {
      if (mounted) {
        state = state.copyWith(lastError: 'PRINT_STATION_MODE_SAVE_FAILED');
      }
      return false;
    } finally {
      if (mounted) {
        state = state.copyWith(isChangingMode: false);
        await _scheduleReconcile();
      }
    }
  }

  Future<void> syncSession({
    required bool authenticated,
    required String? role,
    required String? storeId,
  }) async {
    _authenticated = authenticated;
    _role = role;
    _storeId = storeId;
    await _scheduleReconcile();
  }

  Future<void> _scheduleReconcile() {
    final completer = Completer<void>();
    _transition = _transition
        .then((_) => _reconcile())
        .then((_) {
          if (!completer.isCompleted) completer.complete();
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  Future<void> _reconcile() async {
    if (!state.preferenceLoaded || state.isChangingMode) return;
    if (!_agent.isSupported) {
      await _agent.stopSafely();
      state = state.copyWith(
        status: PrintAgentStatus.unsupported,
        clearStore: true,
      );
      return;
    }

    final canStart =
        state.enabled &&
        state.mode != null &&
        _authenticated &&
        roleCanRun(_role) &&
        _storeId != null &&
        _storeId!.isNotEmpty;
    if (!canStart) {
      await _agent.configureReceiptOnly(
        state.mode == PrintStationMode.paperless,
      );
      state = state.copyWith(
        status: state.enabled
            ? PrintAgentStatus.stopped
            : PrintAgentStatus.disabled,
        clearStore: true,
      );
      return;
    }

    if (state.isRunning && state.activeStoreId == _storeId) return;
    state = state.copyWith(
      status: PrintAgentStatus.starting,
      activeStoreId: _storeId,
      clearError: true,
    );
    try {
      await _agent.stopSafely();
      await _agent.startPollingSafely(
        _storeId!,
        receiptOnly: state.mode == PrintStationMode.paperless,
      );
      state = state.copyWith(
        status: PrintAgentStatus.running,
        activeStoreId: _storeId,
        clearError: true,
      );
    } catch (_) {
      await _agent.stopSafely();
      state = state.copyWith(
        status: PrintAgentStatus.degraded,
        lastError: 'PRINT_AGENT_START_FAILED',
        clearStore: true,
      );
    }
  }

  Future<List<PrintJobAgentResult>> processOnce() async {
    final storeId = state.activeStoreId;
    if (storeId == null || !state.isRunning || state.isChangingMode) {
      return const [];
    }
    try {
      final results = await _agent.processOnce(storeId);
      final successful = results
          .where((result) => result.result == PrintResult.success)
          .length;
      state = state.copyWith(
        lastProcessed: results.length,
        lastSuccessful: successful,
        clearError: true,
      );
      return results;
    } catch (_) {
      state = state.copyWith(
        status: PrintAgentStatus.degraded,
        lastError: 'PRINT_AGENT_PROCESS_FAILED',
      );
      return const [];
    }
  }

  Future<PrintResult> testDestination(String destinationId) {
    return _agent.testPrintDestination(destinationId);
  }

  Future<PrinterTestReport> diagnoseDestination(
    String destinationId, {
    required bool printTicket,
  }) async {
    if (_agent is DiagnosticPrintAgent) {
      return (_agent as DiagnosticPrintAgent).diagnoseDestination(
        destinationId,
        printTicket: printTicket,
      );
    }
    return PrinterTestReport(
      result: printTicket
          ? await testDestination(destinationId)
          : PrintResult.notSupported,
    );
  }

  @override
  void dispose() {
    unawaited(_agent.stopSafely());
    super.dispose();
  }
}
