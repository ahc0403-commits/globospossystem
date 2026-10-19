import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';

enum ServiceConnectivityKind {
  unknown,
  online,
  networkUnavailable,
  serverDegraded,
  authRequired,
  realtimeDegraded,
}

enum ConnectivityFailureKind { network, server, auth, realtime }

class ServiceConnectivityState {
  const ServiceConnectivityState({
    this.kind = ServiceConnectivityKind.unknown,
    this.lastSuccessAt,
    this.consecutiveNetworkFailures = 0,
    this.lastStatusCode,
  });

  final ServiceConnectivityKind kind;
  final DateTime? lastSuccessAt;
  final int consecutiveNetworkFailures;
  final int? lastStatusCode;

  /// Legacy online-only actions may still be attempted while the server is
  /// slow. The authoritative RPC remains responsible for auth and financial
  /// validation. A confirmed transport outage or expired auth blocks them.
  bool get canAttemptOnlineWork =>
      kind != ServiceConnectivityKind.networkUnavailable &&
      kind != ServiceConnectivityKind.authRequired;

  bool get hasConfirmedNetworkOutage =>
      kind == ServiceConnectivityKind.networkUnavailable;
}

class ConnectivityProbeResult {
  const ConnectivityProbeResult._({
    required this.reachable,
    this.failureKind,
    this.statusCode,
  });

  const ConnectivityProbeResult.reachable({int? statusCode})
    : this._(reachable: true, statusCode: statusCode);

  const ConnectivityProbeResult.failed(
    ConnectivityFailureKind kind, {
    int? statusCode,
  }) : this._(reachable: false, failureKind: kind, statusCode: statusCode);

  final bool reachable;
  final ConnectivityFailureKind? failureKind;
  final int? statusCode;
}

typedef ConnectivityProbe = Future<ConnectivityProbeResult> Function();

class ConnectivityStateMachine {
  ConnectivityStateMachine({this.networkFailureThreshold = 2});

  final int networkFailureThreshold;
  ServiceConnectivityState _state = const ServiceConnectivityState();

  ServiceConnectivityState get state => _state;

  ServiceConnectivityState record(
    ConnectivityProbeResult result, {
    DateTime? now,
  }) {
    if (result.reachable) {
      return _state = ServiceConnectivityState(
        kind: ServiceConnectivityKind.online,
        lastSuccessAt: now ?? DateTime.now().toUtc(),
        lastStatusCode: result.statusCode,
      );
    }

    final failure = result.failureKind ?? ConnectivityFailureKind.server;
    if (failure == ConnectivityFailureKind.network) {
      final failures = _state.consecutiveNetworkFailures + 1;
      final confirmed = failures >= networkFailureThreshold;
      return _state = ServiceConnectivityState(
        kind: confirmed
            ? ServiceConnectivityKind.networkUnavailable
            : _state.kind == ServiceConnectivityKind.online
            ? ServiceConnectivityKind.online
            : ServiceConnectivityKind.serverDegraded,
        lastSuccessAt: _state.lastSuccessAt,
        consecutiveNetworkFailures: failures,
        lastStatusCode: result.statusCode,
      );
    }

    final kind = switch (failure) {
      ConnectivityFailureKind.server => ServiceConnectivityKind.serverDegraded,
      ConnectivityFailureKind.auth => ServiceConnectivityKind.authRequired,
      ConnectivityFailureKind.realtime =>
        ServiceConnectivityKind.realtimeDegraded,
      ConnectivityFailureKind.network =>
        ServiceConnectivityKind.networkUnavailable,
    };
    return _state = ServiceConnectivityState(
      kind: kind,
      lastSuccessAt: _state.lastSuccessAt,
      lastStatusCode: result.statusCode,
    );
  }
}

class ConnectivityService {
  ConnectivityService({
    required ConnectivityProbe probe,
    ConnectivityStateMachine? stateMachine,
    this.refreshInterval = const Duration(seconds: 30),
    Random? random,
  }) : _probe = probe,
       _stateMachine = stateMachine ?? ConnectivityStateMachine(),
       _random = random ?? Random();

  final ConnectivityProbe _probe;
  final ConnectivityStateMachine _stateMachine;
  final Duration refreshInterval;
  final Random _random;
  final StreamController<ServiceConnectivityState> _controller =
      StreamController<ServiceConnectivityState>.broadcast();

  Timer? _timer;
  Future<void>? _refreshInFlight;
  bool _refreshRequested = false;
  bool _disposed = false;

  ServiceConnectivityState get current => _stateMachine.state;
  Stream<ServiceConnectivityState> get stream => _controller.stream;

  void start() {
    if (_disposed || _timer != null || _refreshInFlight != null) return;
    unawaited(refresh());
    _scheduleNextProbe();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    final active = _refreshInFlight;
    if (active != null) {
      _refreshRequested = true;
      return active;
    }

    final operation = _runRefresh();
    _refreshInFlight = operation;
    return operation.whenComplete(() {
      _refreshInFlight = null;
      if (_refreshRequested && !_disposed) {
        _refreshRequested = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _runRefresh() async {
    ConnectivityProbeResult result;
    try {
      result = await _probe();
    } on TimeoutException {
      result = const ConnectivityProbeResult.failed(
        ConnectivityFailureKind.server,
      );
    } on http.ClientException {
      result = const ConnectivityProbeResult.failed(
        ConnectivityFailureKind.network,
      );
    } catch (_) {
      // Configuration, parsing, and server-library failures are not proof that
      // the device lost internet access.
      result = const ConnectivityProbeResult.failed(
        ConnectivityFailureKind.server,
      );
    }
    _publish(_stateMachine.record(result));
  }

  void recordRequestSuccess({DateTime? at}) {
    _publish(
      _stateMachine.record(const ConnectivityProbeResult.reachable(), now: at),
    );
  }

  void recordFailure(ConnectivityFailureKind kind, {int? statusCode}) {
    _publish(
      _stateMachine.record(
        ConnectivityProbeResult.failed(kind, statusCode: statusCode),
      ),
    );
  }

  void _publish(ServiceConnectivityState state) {
    if (!_controller.isClosed) _controller.add(state);
  }

  void _scheduleNextProbe() {
    if (_disposed) return;
    final baseMs = refreshInterval.inMilliseconds;
    final jitterMs = min(5000, max(0, baseMs ~/ 6));
    final offset = jitterMs == 0 ? 0 : _random.nextInt((jitterMs * 2) + 1);
    final delayMs = max(1000, baseMs - jitterMs + offset);
    _timer = Timer(Duration(milliseconds: delayMs), () {
      _timer = null;
      if (!_disposed) {
        unawaited(refresh());
        _scheduleNextProbe();
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}

Future<ConnectivityProbeResult> _probeSupabaseHealth() async {
  final response = await http
      .get(
        Uri.parse('${AppConstants.supabaseUrl}/auth/v1/health'),
        headers: {'apikey': AppConstants.supabaseAnonKey},
      )
      .timeout(const Duration(seconds: 4));

  if (response.statusCode == 429 || response.statusCode >= 500) {
    return ConnectivityProbeResult.failed(
      ConnectivityFailureKind.server,
      statusCode: response.statusCode,
    );
  }

  // Any other HTTP response proves that DNS/TLS/transport reached the service.
  // Business RPCs classify their own auth and authorization failures.
  return ConnectivityProbeResult.reachable(statusCode: response.statusCode);
}

final connectivityProbeProvider = Provider<ConnectivityProbe>(
  (ref) => _probeSupabaseHealth,
);

final connectivityServiceProvider = Provider.autoDispose<ConnectivityService>((
  ref,
) {
  final service = ConnectivityService(
    probe: ref.watch(connectivityProbeProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  service.start();
  return service;
});

final serviceConnectivityProvider =
    StreamProvider.autoDispose<ServiceConnectivityState>((ref) async* {
      final service = ref.watch(connectivityServiceProvider);
      yield service.current;
      yield* service.stream;
    });

/// Compatibility surface for existing online-only controls. Server slowness is
/// deliberately not reported as an internet outage.
final connectivityProvider = StreamProvider.autoDispose<bool>((ref) async* {
  final service = ref.watch(connectivityServiceProvider);
  yield service.current.canAttemptOnlineWork;
  yield* service.stream.map((state) => state.canAttemptOnlineWork).distinct();
});
