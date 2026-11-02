import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/auth_http_snapshot.dart';
import '../utils/deadline_http_client.dart';

/// Only the existing own-password/consent contracts. Freezes the original JWT,
/// aborts this operation's HTTP work, and never retries a mutation.
class AuthCommandSession {
  AuthCommandSession(
    this.source,
    this.isCurrent, {
    this.budget = const Duration(seconds: 15),
  }) : _clock = Stopwatch()..start();

  final SupabaseClient source;
  final bool Function() isCurrent;
  final Duration budget;
  final Stopwatch _clock;
  AuthHttpSnapshot? _authorization;
  DeadlineHttpClient? _transport;
  bool _closed = false;

  Future<void> changePassword(
    String password, {
    required bool selfService,
  }) async {
    final value = await _request(
      '/functions/v1/complete-initial-password-change',
      {'new_password': password, if (selfService) 'mode': 'self_service'},
    );
    if (value is! Map || value['password_changed'] != true) {
      throw StateError('PASSWORD_CHANGE_NOT_CONFIRMED');
    }
  }

  Future<void> acceptConsent(String locale) async {
    await _request('/rest/v1/rpc/accept_my_privacy_consent', {
      'p_consent_locale': locale,
    });
  }

  Future<bool> passwordStillRequired(String actorId) async {
    final value = await _request(
      '/rest/v1/users',
      null,
      query: {
        'select': 'must_change_password,password_change_generation',
        'auth_id': 'eq.$actorId',
      },
    );
    // RLS remains authoritative; a successful empty lookup cannot clear a gate.
    if (value is! List || value.length != 1 || value.single is! Map) {
      throw const FormatException('PASSWORD_PROFILE_INVALID');
    }
    return (value.single as Map)['must_change_password'] != false;
  }

  Future<dynamic> _request(
    String path,
    Map<String, dynamic>? body, {
    Map<String, String>? query,
  }) async {
    if (_closed || !isCurrent()) throw StateError('AUTH_COMMAND_SUPERSEDED');
    final encoded = body == null ? null : jsonEncode(body);
    if (encoded != null && utf8.encode(encoded).length > 16 * 1024) {
      throw ArgumentError('AUTH_COMMAND_INPUT_BOUND');
    }
    final remaining = budget - _clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Auth command deadline');
    }
    _authorization ??= await AuthHttpSnapshot.capture(
      source,
      budget: remaining,
    );
    if (_closed || !isCurrent() || !_authorization!.isCurrent()) {
      throw StateError('AUTH_COMMAND_SUPERSEDED');
    }
    final requestBudget = budget - _clock.elapsed;
    if (requestBudget <= Duration.zero) {
      throw TimeoutException('Auth command deadline');
    }
    _transport ??= DeadlineHttpClient(
      source.rest.httpClient!,
      DateTime.now().add(requestBudget),
      callTimeout: requestBudget,
      maxResponseBytes: 64 * 1024,
      responseTooLargeCode: 'AUTH_COMMAND_RESPONSE_BOUND',
      isCurrent: () => !_closed && isCurrent() && _authorization!.isCurrent(),
    );
    final root = source.rest.url;
    if (!root.endsWith('/rest/v1')) {
      throw StateError('AUTH_PROJECT_URL_INVALID');
    }
    final uri = Uri.parse(
      root.substring(0, root.length - '/rest/v1'.length) + path,
    ).replace(queryParameters: query);
    final response =
        await (encoded == null
                ? _transport!.get(uri, headers: _authorization!.headers)
                : _transport!.post(
                    uri,
                    headers: {
                      ..._authorization!.headers,
                      'Content-Type': 'application/json',
                    },
                    body: encoded,
                  ))
            .timeout(requestBudget);
    if (_closed || !isCurrent()) throw StateError('AUTH_COMMAND_SUPERSEDED');
    final value = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (path.startsWith('/rest/') && value is Map) {
        throw PostgrestException(
          message: value['message']?.toString() ?? 'AUTH_COMMAND_REJECTED',
          code: value['code']?.toString(),
        );
      }
      throw StateError('AUTH_COMMAND_REJECTED');
    }
    return value;
  }

  void close() {
    _closed = true;
    _transport?.close();
  }
}
