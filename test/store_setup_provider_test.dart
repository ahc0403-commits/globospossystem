import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_provider.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';

void main() {
  test(
    'paperless USB store loads, applies and completes one receipt test',
    () async {
      final backend = _FakeStoreSetupBackend()
        ..operation = StorePrinterOperation.paperless
        ..usbName = 'XP-80C';
      final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
      await _flush();
      expect(notifier.state.draft.operation, StorePrinterOperation.paperless);
      final printer =
          notifier.state.draft.printers[PhysicalPrinterSlot.cashier]!;
      expect(printer.connection, SetupPrinterConnection.usb);
      expect(printer.usbPrinterName, 'XP-80C');
      expect(printer.ip, isEmpty);
      expect(await notifier.validate(), isTrue);
      expect(await notifier.apply(), isTrue);
      await notifier.runAllTests();
      expect(backend.enqueueCalls, 1);
      expect(notifier.state.allTestJobsDone, isTrue);
      expect(notifier.state.operationallyReady, isFalse);
      notifier.confirmPhysicalOutput('TEST-RECEIPT', true);
      expect(notifier.state.operationallyReady, isTrue);
      await notifier.loadExisting();
      expect(
        notifier
            .state
            .draft
            .printers[PhysicalPrinterSlot.cashier]!
            .usbPrinterName,
        'XP-80C',
      );
      expect(notifier.state.allPhysicalOutputsConfirmed, isFalse);
      notifier.dispose();
    },
  );

  test(
    'mode switch clears tests and an in-flight poll cannot revive old evidence',
    () async {
      final backend = _FakeStoreSetupBackend();
      final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
      await _flush();
      await notifier.apply();
      await notifier.runAllTests();
      for (final label in notifier.state.testJobs.keys.toList()) {
        notifier.confirmPhysicalOutput(label, true);
      }
      expect(notifier.state.operationallyReady, isTrue);
      backend.fetchCompleter = Completer<Map<String, Map<String, dynamic>>>();
      final oldPoll = notifier.pollTestJobs();
      notifier.setOperation(StorePrinterOperation.paperless);
      backend.fetchCompleter!.complete({});
      await oldPoll;
      expect(notifier.state.testJobs, isEmpty);
      expect(notifier.state.validation, isNull);
      expect(notifier.state.applyResult, isNull);
      expect(notifier.state.readiness, isNull);
      expect(notifier.state.allPhysicalOutputsConfirmed, isFalse);
      expect(notifier.state.draft.destinations, hasLength(1));
      notifier.dispose();
    },
  );

  test('editing USB name invalidates the completed receipt test', () async {
    final backend = _FakeStoreSetupBackend()
      ..operation = StorePrinterOperation.paperless;
    final notifier = StoreSetupNotifier(storeId: 'store-1', backend: backend);
    await _flush();
    await notifier.apply();
    await notifier.runAllTests();
    notifier.confirmPhysicalOutput('TEST-RECEIPT', true);
    notifier.updatePrinter(
      notifier.state.draft.printers[PhysicalPrinterSlot.cashier]!.copyWith(
        connection: SetupPrinterConnection.usb,
        usbPrinterName: 'XP-80C',
      ),
    );
    expect(notifier.state.testJobs, isEmpty);
    expect(notifier.state.operationallyReady, isFalse);
    notifier.dispose();
  });

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
  StorePrinterOperation operation = StorePrinterOperation.posPrint;
  String usbName = '';
  Completer<Map<String, Map<String, dynamic>>>? fetchCompleter;
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
      operation: operation,
    ))
      {
        'id': 'destination-${route.label}',
        'name': route.name,
        'ip': '192.168.1.10',
        'port': 9100,
        'purpose': route.purpose,
        'floor_label': route.floorLabel,
        'is_active': true,
        if (usbName.isNotEmpty)
          'physical_printers': {
            'name': 'Cashier',
            'printer_endpoints': [
              {
                'endpoint_type': 'usb',
                'device_name': usbName,
                'port': 9100,
                'priority': 5,
                'is_active': true,
              },
            ],
          },
      },
  ];

  @override
  Future<Map<String, dynamic>> apply(StoreOpeningDraft draft) async {
    operation = draft.operation;
    return {'store_id': draft.storeId};
  }

  @override
  Future<List<StoreSetupTestJob>> enqueueTests({
    required String storeId,
    required Map<String, LogicalDestinationDraft> destinationsById,
  }) async {
    enqueueCalls += destinationsById.length;
    return [
      for (final entry in destinationsById.entries)
        StoreSetupTestJob(
          label: entry.value.label,
          destinationId: entry.key,
          jobId: 'job-${entry.value.label}',
        ),
    ];
  }

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
  ) async => fetchCompleter != null
      ? fetchCompleter!.future
      : {
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
      operation: operation,
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
