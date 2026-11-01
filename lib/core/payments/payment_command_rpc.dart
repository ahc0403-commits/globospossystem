import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/auth_http_snapshot.dart';
import '../utils/deadline_http_client.dart';
import '../utils/rpc_resource_cleanup.dart';

enum PaymentCommandRpcKind {
  execute('process_single_payment_command_v2'),
  cancel('cancel_single_payment_command_v1'),
  receipts('get_payment_command_receipts_v1');

  const PaymentCommandRpcKind(this.rpc);
  final String rpc;
}

/// Transport ownership only. The caller must persist the original intent before
/// executing and reconcile an uncertain result; this class never retries.
class PaymentCommandRpc {
  PaymentCommandRpc(this.source);
  final SupabaseClient source;

  Future<dynamic> call(
    PaymentCommandRpcKind kind,
    Map<String, dynamic> params, {
    required bool Function() isCurrent,
    Duration budget = const Duration(seconds: 15),
  }) async {
    final clock = Stopwatch()..start();
    if (!isCurrent()) throw StateError('PAYMENT_COMMAND_SCOPE_CHANGED');
    // Freeze identity/payload before any Auth or JSON-worker await.
    final encoded = jsonEncode(params);
    if (utf8.encode(encoded).length > 64 * 1024 || budget <= Duration.zero) {
      throw ArgumentError('PAYMENT_COMMAND_INPUT_BOUND');
    }
    final snapshot = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final authBudget = budget - clock.elapsed;
    if (authBudget <= Duration.zero) {
      throw TimeoutException('Payment command deadline reached');
    }
    final authorization = await AuthHttpSnapshot.capture(
      source,
      budget: authBudget,
    );
    if (!isCurrent() || !authorization.isCurrent()) {
      throw StateError('PAYMENT_COMMAND_SCOPE_CHANGED');
    }
    final remaining = budget - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Payment command deadline reached');
    }
    final transport = DeadlineHttpClient(
      source.rest.httpClient!,
      DateTime.now().add(remaining),
      callTimeout: remaining,
      maxResponseBytes: 512 * 1024,
      responseTooLargeCode: 'PAYMENT_COMMAND_RESPONSE_TOO_LARGE',
      isCurrent: () => isCurrent() && authorization.isCurrent(),
    );
    final db = PostgrestClient(
      source.rest.url,
      headers: authorization.headers,
      httpClient: transport,
    );
    try {
      return await db.rpc(kind.rpc, params: snapshot).timeout(remaining);
    } finally {
      transport.close();
      await disposeRpcJsonWorker(db.dispose);
    }
  }
}
