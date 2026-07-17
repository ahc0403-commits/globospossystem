import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/print_agent_coordinator.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';

void main() {
  test(
    'device preference defaults off and no session starts an agent',
    () async {
      final driver = _FakeDriver();
      final preferences = _FakePreferences();
      final coordinator = PrintAgentCoordinator(
        agent: driver,
        preferenceStore: preferences,
      );
      await _flush();
      await coordinator.syncSession(
        authenticated: true,
        role: 'cashier',
        storeId: 'store-1',
      );

      expect(coordinator.state.enabled, isFalse);
      expect(driver.startedStores, isEmpty);
      coordinator.dispose();
    },
  );

  test(
    'enabled agent survives navigation, stops logout, and restarts cashier',
    () async {
      final driver = _FakeDriver();
      final preferences = _FakePreferences();
      final coordinator = PrintAgentCoordinator(
        agent: driver,
        preferenceStore: preferences,
      );
      await _flush();
      await coordinator.syncSession(
        authenticated: true,
        role: 'admin',
        storeId: 'store-1',
      );
      await coordinator.setEnabled(true);
      expect(driver.startedStores, ['store-1']);

      // A rebuild/navigation sync with the same scope keeps the one instance.
      await coordinator.syncSession(
        authenticated: true,
        role: 'admin',
        storeId: 'store-1',
      );
      expect(driver.startedStores, ['store-1']);

      await coordinator.syncSession(
        authenticated: false,
        role: null,
        storeId: null,
      );
      expect(coordinator.state.enabled, isTrue);
      expect(coordinator.state.status, PrintAgentStatus.stopped);

      await coordinator.syncSession(
        authenticated: true,
        role: 'cashier',
        storeId: 'store-1',
      );
      expect(driver.startedStores, ['store-1', 'store-1']);
      expect(coordinator.state.status, PrintAgentStatus.running);
      coordinator.dispose();
    },
  );

  test('store switch unsubscribes before the next store starts', () async {
    final driver = _FakeDriver();
    final coordinator = PrintAgentCoordinator(
      agent: driver,
      preferenceStore: _FakePreferences(enabled: true),
    );
    await _flush();
    await coordinator.syncSession(
      authenticated: true,
      role: 'store_admin',
      storeId: 'store-1',
    );
    await coordinator.syncSession(
      authenticated: true,
      role: 'store_admin',
      storeId: 'store-2',
    );

    expect(driver.startedStores, ['store-1', 'store-2']);
    expect(
      driver.events,
      containsAllInOrder(['stop', 'start:store-1', 'stop', 'start:store-2']),
    );
    coordinator.dispose();
  });

  test('unsupported runtime never starts the native driver', () async {
    final driver = _FakeDriver(supported: false);
    final coordinator = PrintAgentCoordinator(
      agent: driver,
      preferenceStore: _FakePreferences(enabled: true),
    );
    await _flush();
    await coordinator.syncSession(
      authenticated: true,
      role: 'admin',
      storeId: 'store-1',
    );

    expect(driver.startedStores, isEmpty);
    expect(coordinator.state.status, PrintAgentStatus.unsupported);
    coordinator.dispose();
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _FakePreferences implements PrintAgentPreferenceStore {
  _FakePreferences({this.enabled = false});
  bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

class _FakeDriver implements PrintAgentDriver {
  _FakeDriver({this.supported = true});
  final bool supported;
  final List<String> startedStores = [];
  final List<String> events = [];

  @override
  bool get isSupported => supported;

  @override
  Future<List<PrintJobAgentResult>> processOnce(
    String storeId, {
    int limit = 10,
  }) async => const [];

  @override
  Future<void> startPollingSafely(String storeId) async {
    events.add('start:$storeId');
    startedStores.add(storeId);
  }

  @override
  Future<void> stopSafely() async => events.add('stop');

  @override
  Future<PrintResult> testPrintDestination(String destinationId) async =>
      PrintResult.success;
}
