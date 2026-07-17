import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_provider.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';

void main() {
  test('provider prevents concurrent validation', () async {
    final backend = _FakeStoreSetupBackend();
    final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
    await _flush();
    backend.validationCompleter = Completer<StoreSetupValidationResult>();

    final first = notifier.validate();
    final second = await notifier.validate();
    expect(second, isFalse);
    expect(backend.validateCalls, 1);

    backend.validationCompleter!.complete(
      const StoreSetupValidationResult(valid: true),
    );
    expect(await first, isTrue);
    notifier.dispose();
  });

  test('five returned job IDs are retained, polled, and confirmed', () async {
    final backend = _FakeStoreSetupBackend();
    final notifier = StoreSetupNotifier(
      storeId: 'store-1',
      backend: backend,
      pollingInterval: const Duration(hours: 1),
    );
    await _flush();
    expect(await notifier.validate(), isTrue);
    expect(await notifier.apply(), isTrue);

    await notifier.runAllTests();

    expect(notifier.state.testJobs, hasLength(5));
    expect(
      notifier.state.testJobs.values.map((job) => job.jobId).toSet(),
      hasLength(5),
    );
    expect(
      notifier.state.testJobs.values.every((job) => job.status == 'done'),
      isTrue,
    );
    for (final label in notifier.state.testJobs.keys.toList()) {
      notifier.confirmPhysicalOutput(label, true);
    }
    expect(notifier.state.allPhysicalOutputsConfirmed, isTrue);
    expect(notifier.state.operationallyReady, isTrue);
    notifier.dispose();
  });

  test('printer test retry ignores a concurrent second submission', () async {
    final backend = _FakeStoreSetupBackend();
    final notifier = StoreSetupNotifier(
      storeId: 'store-1',
      backend: backend,
      pollingInterval: const Duration(hours: 1),
    );
    await _flush();
    expect(await notifier.validate(), isTrue);
    expect(await notifier.apply(), isTrue);
    await notifier.runAllTests();

    final label = notifier.state.testJobs.keys.first;
    final previous = notifier.state.testJobs[label]!;
    backend.enqueueCompleter = Completer<StoreSetupTestJob>();
    final first = notifier.retryTest(label);
    final second = notifier.retryTest(label);
    await _flush();

    expect(backend.enqueueCalls, 6);
    backend.enqueueCompleter!.complete(
      StoreSetupTestJob(
        label: label,
        destinationId: previous.destinationId,
        jobId: 'retry-$label',
      ),
    );
    await Future.wait([first, second]);
    expect(notifier.state.testJobs[label]!.jobId, 'retry-$label');
    notifier.dispose();
  });

  test(
    'fixed-account provisioning clears transient state after success',
    () async {
      final backend = _FakeStoreSetupBackend();
      final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
      await _flush();

      final result = await notifier.provisionFixedAccount(
        requirementId: 'requirement-1',
        password: 'twelve-chars',
      );

      expect(result, isTrue);
      expect(backend.provisionCalls, 1);
      expect(backend.lastProvisionRequirementId, 'requirement-1');
      expect(backend.lastProvisionPasswordLength, 12);
      expect(notifier.state.provisioningAccountId, isNull);
      expect(notifier.state.errorCode, isNull);
      notifier.dispose();
    },
  );

  test(
    'fixed-account provisioning clears transient state after failure',
    () async {
      final backend = _FakeStoreSetupBackend()..provisionShouldFail = true;
      final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
      await _flush();

      final result = await notifier.provisionFixedAccount(
        requirementId: 'requirement-2',
        password: 'twelve-chars',
      );

      expect(result, isFalse);
      expect(notifier.state.provisioningAccountId, isNull);
      expect(
        notifier.state.errorCode,
        'STORE_SETUP_FIXED_ACCOUNT_PROVISION_FAILED',
      );
      notifier.dispose();
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _FakeStoreSetupBackend implements StoreSetupBackend {
  int validateCalls = 0;
  int enqueueCalls = 0;
  int provisionCalls = 0;
  bool provisionShouldFail = false;
  String? lastProvisionRequirementId;
  int? lastProvisionPasswordLength;
  Completer<StoreSetupValidationResult>? validationCompleter;
  Completer<StoreSetupTestJob>? enqueueCompleter;

  List<Map<String, dynamic>> get destinations => [
    for (final route in StoreOpeningTemplate.deriveDestinations(
      StoreOpeningTemplate.defaultPrinters(),
    ))
      {
        'id': 'destination-${route.label}',
        'name': route.name,
        'ip': '192.168.1.10',
        'port': 9100,
        'purpose': route.purpose,
        'floor_label': route.floorLabel,
        'is_active': true,
      },
  ];

  @override
  Future<Map<String, dynamic>> apply(StoreOpeningDraft draft) async => {
    'store_id': draft.storeId,
  };

  @override
  Future<StoreSetupTestJob> enqueueTest({
    required String storeId,
    required LogicalDestinationDraft destination,
    required String destinationId,
  }) async {
    enqueueCalls++;
    if (enqueueCompleter != null) return enqueueCompleter!.future;
    return StoreSetupTestJob(
      label: destination.label,
      destinationId: destinationId,
      jobId: 'job-${destination.label}',
    );
  }

  @override
  Future<Map<String, Map<String, dynamic>>> fetchTestJobs(
    String storeId,
    Iterable<String> jobIds,
  ) async => {
    for (final id in jobIds) id: {'id': id, 'status': 'done'},
  };

  @override
  Future<StoreSetupExistingConfig> loadExisting(String storeId) async {
    return StoreSetupExistingConfig(
      store: {'id': storeId, 'name': 'Test Store', 'is_active': true},
      tables: const [
        StoreSetupTableDraft(
          tableNumber: '101',
          seatCount: 4,
          floorLabel: '1F',
          existingId: 'table-1',
          existingStatus: 'available',
        ),
      ],
      destinations: destinations,
    );
  }

  @override
  Future<Map<String, dynamic>> readiness(String storeId) async => {
    'ready': true,
    'checks': [],
    'recovery': [],
  };

  @override
  Future<Map<String, dynamic>> workforceReadiness(String storeId) async => {
    'short_code': 'TEST',
    'management_model': 'store_managed',
    'account_templates_configured': true,
    'accounts_ready': true,
    'employees_active': 1,
    'required_accounts': [],
    'missing_accounts': [],
  };

  @override
  Future<Map<String, dynamic>> configureWorkforce({
    required String storeId,
    required String shortCode,
    required String managementModel,
    required int brandManagerSlots,
    required List<WorkforceAccountTemplate> accountTemplates,
  }) async => {'store_id': storeId};

  @override
  Future<Map<String, dynamic>> provisionFixedAccount({
    required String requirementId,
    required String password,
  }) async {
    provisionCalls++;
    lastProvisionRequirementId = requirementId;
    lastProvisionPasswordLength = password.length;
    if (provisionShouldFail) throw Exception('provision failed');
    return {'requirement_id': requirementId};
  }

  @override
  Future<StoreSetupValidationResult> validate(StoreOpeningDraft draft) {
    validateCalls++;
    return validationCompleter?.future ??
        Future.value(const StoreSetupValidationResult(valid: true));
  }
}
