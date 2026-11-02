import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/auth_http_snapshot.dart';
import '../utils/deadline_http_client.dart';
import '../utils/rpc_resource_cleanup.dart';

enum OrderCommandRpcKind {
  create('create_order_for_business_day'),
  add('add_order_items_once_v1'),
  createReceipts('get_order_create_receipts_v1'),
  addReceipts('get_order_add_receipts_v1'),
  batch('execute_order_command_batch_v1');

  const OrderCommandRpcKind(this.rpc);
  final String rpc;
}

bool _current() => true;

/// Transport ownership only. The caller must persist the original intent before
/// executing and reconcile an uncertain result; this class never retries.
class OrderCommandRpc {
  OrderCommandRpc(this.source);
  final SupabaseClient source;

  Future<dynamic> call(
    OrderCommandRpcKind kind,
    Map<String, dynamic> params, {
    bool Function() isCurrent = _current,
    Duration budget = const Duration(seconds: 15),
  }) async {
    final clock = Stopwatch()..start();
    if (!isCurrent()) throw StateError('ORDER_COMMAND_SCOPE_CHANGED');
    // Freeze identity/payload before any Auth or JSON-worker await.
    final encoded = jsonEncode(params);
    if (utf8.encode(encoded).length > 1024 * 1024 || budget <= Duration.zero) {
      throw ArgumentError('ORDER_COMMAND_INPUT_BOUND');
    }
    final snapshot = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final authBudget = budget - clock.elapsed;
    if (authBudget <= Duration.zero) {
      throw TimeoutException('Order command deadline reached');
    }
    final authorization = await AuthHttpSnapshot.capture(
      source,
      budget: authBudget,
    );
    if (!isCurrent() || !authorization.isCurrent()) {
      throw StateError('ORDER_COMMAND_SCOPE_CHANGED');
    }
    final remaining = budget - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Order command deadline reached');
    }
    final transport = DeadlineHttpClient(
      source.rest.httpClient!,
      DateTime.now().add(remaining),
      callTimeout: remaining,
      maxResponseBytes: 4 * 1024 * 1024,
      responseTooLargeCode: 'ORDER_COMMAND_RESPONSE_TOO_LARGE',
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
