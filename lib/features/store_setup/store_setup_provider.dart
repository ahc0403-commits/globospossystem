import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'store_setup_models.dart';
import 'store_setup_service.dart';

enum StoreSetupPhase {
  loadingExisting,
  editing,
  validating,
  readyToApply,
  applying,
  applied,
  testing,
  ready,
  blocked,
}

class StoreSetupState {
  const StoreSetupState({
    required this.draft,
    this.phase = StoreSetupPhase.loadingExisting,
    this.step = 0,
    this.store = const {},
    this.existingDestinations = const [],
    this.validation,
    this.applyResult,
    this.readiness,
    this.testJobs = const {},
    this.errorCode,
  });

  final StoreOpeningDraft draft;
  final StoreSetupPhase phase;
  final int step;
  final Map<String, dynamic> store;
  final List<Map<String, dynamic>> existingDestinations;
  final StoreSetupValidationResult? validation;
  final Map<String, dynamic>? applyResult;
  final Map<String, dynamic>? readiness;
  final Map<String, StoreSetupTestJob> testJobs;
  final String? errorCode;

  bool get isBusy =>
      phase == StoreSetupPhase.loadingExisting ||
      phase == StoreSetupPhase.validating ||
      phase == StoreSetupPhase.applying;

  bool get allTestJobsDone =>
      testJobs.length == 5 &&
      testJobs.values.every((job) => job.status == 'done');

  bool get allPhysicalOutputsConfirmed =>
      testJobs.length == 5 &&
      testJobs.values.every((job) => job.physicallyConfirmed);

  bool get operationallyReady =>
      readiness?['ready'] == true &&
      allTestJobsDone &&
      allPhysicalOutputsConfirmed;

  StoreSetupState copyWith({
    StoreOpeningDraft? draft,
    StoreSetupPhase? phase,
    int? step,
    Map<String, dynamic>? store,
    List<Map<String, dynamic>>? existingDestinations,
    StoreSetupValidationResult? validation,
    Map<String, dynamic>? applyResult,
    Map<String, dynamic>? readiness,
    Map<String, StoreSetupTestJob>? testJobs,
    String? errorCode,
    bool clearValidation = false,
    bool clearApplyResult = false,
    bool clearReadiness = false,
    bool clearError = false,
  }) {
    return StoreSetupState(
      draft: draft ?? this.draft,
      phase: phase ?? this.phase,
      step: step ?? this.step,
      store: store ?? this.store,
      existingDestinations: existingDestinations ?? this.existingDestinations,
      validation: clearValidation ? null : (validation ?? this.validation),
      applyResult: clearApplyResult ? null : (applyResult ?? this.applyResult),
      readiness: clearReadiness ? null : (readiness ?? this.readiness),
      testJobs: testJobs ?? this.testJobs,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
    );
  }
}

class StoreSetupNotifier extends StateNotifier<StoreSetupState> {
  StoreSetupNotifier({
    required String storeId,
    required StoreSetupBackend backend,
    Duration pollingInterval = const Duration(seconds: 2),
    Duration pollingTimeout = const Duration(minutes: 2),
  }) : _backend = backend,
       _pollingInterval = pollingInterval,
       _pollingTimeout = pollingTimeout,
       super(
         StoreSetupState(
           draft: StoreOpeningDraft(
             storeId: storeId,
             printers: StoreOpeningTemplate.defaultPrinters(),
           ),
         ),
       ) {
    unawaited(loadExisting());
  }

  final StoreSetupBackend _backend;
  final Duration _pollingInterval;
  final Duration _pollingTimeout;
  Timer? _pollTimer;
  DateTime? _pollDeadline;
  bool _operationInFlight = false;
  bool _pollInFlight = false;

  Future<void> loadExisting() async {
    state = state.copyWith(
      phase: StoreSetupPhase.loadingExisting,
      clearError: true,
    );
    try {
      final existing = await _backend.loadExisting(state.draft.storeId);
      final printers = _printersFromExisting(existing.destinations);
      state = state.copyWith(
        phase: StoreSetupPhase.editing,
        store: existing.store,
        existingDestinations: existing.destinations,
        draft: state.draft.copyWith(
          tables: existing.tables,
          printers: printers,
        ),
        clearValidation: true,
        clearError: true,
      );
      await refreshReadiness(silent: true);
    } catch (_) {
      state = state.copyWith(
        phase: StoreSetupPhase.blocked,
        errorCode: 'STORE_SETUP_LOAD_FAILED',
      );
    }
  }

  Map<PhysicalPrinterSlot, PhysicalPrinterDraft> _printersFromExisting(
    List<Map<String, dynamic>> destinations,
  ) {
    final result = StoreOpeningTemplate.defaultPrinters();
    Map<String, dynamic>? find(String purpose, [String? floor]) {
      for (final row in destinations) {
        if (row['is_active'] != true || row['purpose'] != purpose) continue;
        if (purpose != 'floor' ||
            normalizeFloorLabel(row['floor_label']?.toString() ?? '') ==
                floor) {
          return row;
        }
      }
      return null;
    }

    void assign(PhysicalPrinterSlot slot, Map<String, dynamic>? row) {
      if (row == null) return;
      result[slot] = result[slot]!.copyWith(
        name: row['name']?.toString(),
        ip: row['ip']?.toString(),
        port: row['port'] is num ? (row['port'] as num).toInt() : null,
      );
    }

    assign(PhysicalPrinterSlot.cashier, find('receipt') ?? find('floor', '1F'));
    assign(PhysicalPrinterSlot.kitchen, find('kitchen'));
    assign(PhysicalPrinterSlot.floor2, find('floor', '2F'));
    assign(PhysicalPrinterSlot.floor3, find('floor', '3F'));
    return result;
  }

  void goToStep(int step) {
    if (step < 0 || step > 5 || state.isBusy) return;
    state = state.copyWith(step: step, clearError: true);
  }

  void addTables(Iterable<StoreSetupTableDraft> tables) {
    final merged = [...state.draft.tables, ...tables];
    state = state.copyWith(
      phase: StoreSetupPhase.editing,
      draft: state.draft.copyWith(tables: merged),
      clearValidation: true,
      clearApplyResult: true,
      clearReadiness: true,
      clearError: true,
    );
  }

  void removeTableAt(int index) {
    if (index < 0 || index >= state.draft.tables.length) return;
    final table = state.draft.tables[index];
    if (table.existingId != null || table.isProtected) return;
    final updated = [...state.draft.tables]..removeAt(index);
    state = state.copyWith(
      phase: StoreSetupPhase.editing,
      draft: state.draft.copyWith(tables: updated),
      clearValidation: true,
    );
  }

  void reassignTables(Set<int> indexes, String floorLabel) {
    final updated = [...state.draft.tables];
    for (final index in indexes) {
      if (index < 0 || index >= updated.length || updated[index].isProtected) {
        continue;
      }
      updated[index] = updated[index].copyWith(
        floorLabel: normalizeFloorLabel(floorLabel),
      );
    }
    state = state.copyWith(
      phase: StoreSetupPhase.editing,
      draft: state.draft.copyWith(tables: updated),
      clearValidation: true,
    );
  }

  void updatePrinter(PhysicalPrinterDraft printer) {
    state = state.copyWith(
      phase: StoreSetupPhase.editing,
      draft: state.draft.copyWith(
        printers: {...state.draft.printers, printer.slot: printer},
      ),
      clearValidation: true,
      clearApplyResult: true,
      clearReadiness: true,
      clearError: true,
    );
  }

  void setFloor1Slot(PhysicalPrinterSlot slot) {
    state = state.copyWith(
      phase: StoreSetupPhase.editing,
      draft: state.draft.copyWith(floor1Slot: slot),
      clearValidation: true,
    );
  }

  Future<bool> validate() async {
    if (_operationInFlight) return false;
    final duplicates = duplicateTableNumbers(state.draft.tables);
    if (duplicates.isNotEmpty) {
      state = state.copyWith(
        phase: StoreSetupPhase.blocked,
        validation: StoreSetupValidationResult(
          valid: false,
          errors: const ['STORE_SETUP_DUPLICATE_TABLE_NUMBER'],
          plan: {'duplicate_count': duplicates.length},
        ),
      );
      return false;
    }

    _operationInFlight = true;
    state = state.copyWith(phase: StoreSetupPhase.validating, clearError: true);
    try {
      final validation = await _backend.validate(state.draft);
      state = state.copyWith(
        phase: validation.valid
            ? StoreSetupPhase.readyToApply
            : StoreSetupPhase.blocked,
        validation: validation,
        clearError: true,
      );
      return validation.valid;
    } catch (_) {
      state = state.copyWith(
        phase: StoreSetupPhase.editing,
        errorCode: 'STORE_SETUP_VALIDATE_FAILED',
      );
      return false;
    } finally {
      _operationInFlight = false;
    }
  }

  Future<bool> apply() async {
    if (_operationInFlight) return false;
    if (state.validation?.valid != true && !await validate()) return false;
    _operationInFlight = true;
    state = state.copyWith(phase: StoreSetupPhase.applying, clearError: true);
    try {
      final result = await _backend.apply(state.draft);
      final existing = await _backend.loadExisting(state.draft.storeId);
      state = state.copyWith(
        phase: StoreSetupPhase.applied,
        step: 4,
        applyResult: result,
        store: existing.store,
        existingDestinations: existing.destinations,
        clearError: true,
      );
      await refreshReadiness(silent: true);
      return true;
    } catch (_) {
      state = state.copyWith(
        phase: StoreSetupPhase.readyToApply,
        errorCode: 'STORE_SETUP_APPLY_FAILED',
      );
      return false;
    } finally {
      _operationInFlight = false;
    }
  }

  String? _destinationId(LogicalDestinationDraft destination) {
    for (final row in state.existingDestinations) {
      final purpose = row['purpose']?.toString() ?? '';
      final floor = normalizeFloorLabel(row['floor_label']?.toString() ?? '');
      if (row['is_active'] == true &&
          purpose == destination.purpose &&
          (purpose != 'floor' || floor == destination.floorLabel)) {
        return row['id']?.toString();
      }
    }
    return null;
  }

  Future<void> runAllTests() async {
    if (_operationInFlight) return;
    _operationInFlight = true;
    state = state.copyWith(
      phase: StoreSetupPhase.testing,
      step: 5,
      testJobs: const {},
      clearError: true,
    );
    try {
      final jobs = <String, StoreSetupTestJob>{};
      for (final destination in state.draft.destinations) {
        final destinationId = _destinationId(destination);
        if (destinationId == null) {
          throw StateError('STORE_SETUP_DESTINATION_NOT_APPLIED');
        }
        final job = await _backend.enqueueTest(
          storeId: state.draft.storeId,
          destination: destination,
          destinationId: destinationId,
        );
        if (job.jobId.isEmpty) {
          throw StateError('STORE_SETUP_TEST_JOB_ID_MISSING');
        }
        jobs[destination.label] = job;
        state = state.copyWith(testJobs: Map.unmodifiable(jobs));
      }
      _pollDeadline = DateTime.now().add(_pollingTimeout);
      await pollTestJobs();
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        _pollingInterval,
        (_) => unawaited(pollTestJobs()),
      );
    } catch (_) {
      state = state.copyWith(
        phase: StoreSetupPhase.applied,
        errorCode: 'STORE_SETUP_TEST_ENQUEUE_FAILED',
      );
    } finally {
      _operationInFlight = false;
    }
  }

  Future<void> pollTestJobs() async {
    if (state.testJobs.isEmpty || _pollInFlight) return;
    if (_pollDeadline != null && DateTime.now().isAfter(_pollDeadline!)) {
      _pollTimer?.cancel();
      _pollTimer = null;
      state = state.copyWith(errorCode: 'STORE_SETUP_TEST_TIMEOUT');
      return;
    }
    _pollInFlight = true;
    try {
      final rows = await _backend.fetchTestJobs(
        state.draft.storeId,
        state.testJobs.values.map((job) => job.jobId),
      );
      final jobs = <String, StoreSetupTestJob>{};
      for (final entry in state.testJobs.entries) {
        final row = rows[entry.value.jobId];
        jobs[entry.key] = row == null
            ? entry.value
            : entry.value.copyWith(
                status: row['status']?.toString(),
                error: row['last_error']?.toString(),
              );
      }
      state = state.copyWith(testJobs: Map.unmodifiable(jobs));
      if (jobs.values.every((job) => job.isTerminal)) {
        _pollTimer?.cancel();
        _pollTimer = null;
        await refreshReadiness(silent: true);
        state = state.copyWith(
          phase: state.operationallyReady
              ? StoreSetupPhase.ready
              : StoreSetupPhase.testing,
        );
      }
    } catch (_) {
      state = state.copyWith(errorCode: 'STORE_SETUP_TEST_POLL_FAILED');
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> retryTest(String label) async {
    final previous = state.testJobs[label];
    if (previous == null || _operationInFlight) return;
    final destination = state.draft.destinations.firstWhere(
      (item) => item.label == label,
    );
    _operationInFlight = true;
    try {
      final job = await _backend.enqueueTest(
        storeId: state.draft.storeId,
        destination: destination,
        destinationId: previous.destinationId,
      );
      state = state.copyWith(
        phase: StoreSetupPhase.testing,
        testJobs: {
          ...state.testJobs,
          label: job.copyWith(physicallyConfirmed: false),
        },
        clearError: true,
      );
      _pollDeadline = DateTime.now().add(_pollingTimeout);
      _pollTimer ??= Timer.periodic(
        _pollingInterval,
        (_) => unawaited(pollTestJobs()),
      );
    } catch (_) {
      state = state.copyWith(errorCode: 'STORE_SETUP_TEST_ENQUEUE_FAILED');
    } finally {
      _operationInFlight = false;
    }
  }

  void confirmPhysicalOutput(String label, bool confirmed) {
    final job = state.testJobs[label];
    if (job == null || job.status != 'done') return;
    state = state.copyWith(
      testJobs: {
        ...state.testJobs,
        label: job.copyWith(physicallyConfirmed: confirmed),
      },
    );
    if (state.operationallyReady) {
      state = state.copyWith(phase: StoreSetupPhase.ready);
    }
  }

  Future<void> refreshReadiness({bool silent = false}) async {
    try {
      final readiness = await _backend.readiness(state.draft.storeId);
      state = state.copyWith(readiness: readiness, clearError: silent);
    } catch (_) {
      if (!silent) {
        state = state.copyWith(errorCode: 'STORE_SETUP_READINESS_FAILED');
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}

final storeSetupBackendProvider = Provider<StoreSetupBackend>(
  (_) => SupabaseStoreSetupBackend(),
);

final storeSetupProvider = StateNotifierProvider.autoDispose
    .family<StoreSetupNotifier, StoreSetupState, String>((ref, storeId) {
      return StoreSetupNotifier(
        storeId: storeId,
        backend: ref.watch(storeSetupBackendProvider),
      );
    });
