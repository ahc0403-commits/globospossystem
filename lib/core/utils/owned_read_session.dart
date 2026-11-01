import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'deadline_http_client.dart';
import 'auth_http_snapshot.dart';
import 'rpc_resource_cleanup.dart';

/// A single view/query's read ownership. It preserves the shared Auth transport
/// and snapshots its headers, while aborting only this owner's HTTP requests.
/// Callers still own tenant/query keys, epochs and same-query single-flight.
/// Mutations are forbidden; each read RPC must be explicitly reviewed/allowed.
class OwnedReadSession {
  OwnedReadSession({Set<String> allowedRpcs = const {}})
    : _allowedRpcs = Set.unmodifiable(allowedRpcs);

  final Set<String> _allowedRpcs;
  final _requests = RequestLifetime();
  bool _disposed = false;
  bool _running = false;

  Future<T> run<T>(
    SupabaseClient source,
    Future<T> Function(PostgrestClient) read, {
    Duration budget = const Duration(seconds: 15),
    int maxResponseBytes = 4 * 1024 * 1024,
  }) async {
    if (_disposed) throw StateError('READ_OWNER_DISPOSED');
    if (_running) throw StateError('READ_OWNER_ALREADY_RUNNING');
    if (budget <= Duration.zero || maxResponseBytes <= 0) {
      throw ArgumentError('READ_BUDGET_INVALID');
    }
    _running = true;
    final clock = Stopwatch()..start();
    _ReadTransport? transport;
    PostgrestClient? db;
    try {
      final authorization = await AuthHttpSnapshot.capture(
        source,
        budget: budget,
      );
      final remaining = budget - clock.elapsed;
      if (_disposed) throw StateError('READ_OWNER_DISPOSED');
      if (remaining <= Duration.zero) {
        throw TimeoutException('Read session deadline reached');
      }
      transport = _ReadTransport(
        source.rest.httpClient!,
        DateTime.now().add(remaining),
        _allowedRpcs,
        authorization.isCurrent,
        remaining,
        maxResponseBytes,
      );
      _requests.add(transport);
      db = PostgrestClient(
        source.rest.url,
        headers: authorization.headers,
        httpClient: transport,
      );
      // The whole budget includes JSON setup and gaps between bounded reads.
      final callbackBudget = budget - clock.elapsed;
      if (callbackBudget <= Duration.zero) {
        throw TimeoutException('Read session deadline reached');
      }
      return await read(db).timeout(callbackBudget);
    } finally {
      if (transport != null) {
        _requests.remove(transport);
        transport.close();
      }
      if (db != null) await disposeRpcJsonWorker(db.dispose);
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _requests.dispose();
  }
}

class _ReadTransport extends DeadlineHttpClient {
  _ReadTransport(
    super.inner,
    super.deadline,
    this.allowedRpcs,
    this.actorIsCurrent,
    Duration budget,
    int maxBytes,
  ) : super(
        callTimeout: budget,
        maxResponseBytes: maxBytes,
        responseTooLargeCode: 'READ_RESPONSE_TOO_LARGE',
      );

  final Set<String> allowedRpcs;
  final bool Function() actorIsCurrent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!actorIsCurrent()) throw StateError('READ_OWNER_ACTOR_CHANGED');
    final path = request.url.pathSegments;
    final rpc = path.length >= 2 && path[path.length - 2] == 'rpc';
    if (rpc && !allowedRpcs.contains(path.last) ||
        request.method != 'GET' &&
            request.method != 'HEAD' &&
            !(request.method == 'POST' && rpc)) {
      throw StateError('READ_OWNER_MUTATION_FORBIDDEN');
    }
    return super.send(request);
  }
}
