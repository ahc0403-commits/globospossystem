import 'package:supabase_flutter/supabase_flutter.dart';

/// Captures authorization for one original operation. A shared Auth transport
/// may refresh its own session, but may not substitute a later actor's JWT.
class AuthHttpSnapshot {
  AuthHttpSnapshot._(this.headers, this.isCurrent);

  final Map<String, String> headers;
  final bool Function() isCurrent;

  static Future<AuthHttpSnapshot> capture(
    SupabaseClient source, {
    required Duration budget,
  }) async {
    final headers = {...source.rest.headers, ...source.headers};
    final hasAuthorization = headers.keys.any(
      (key) => key.toLowerCase() == 'authorization',
    );
    bool Function() isCurrent;
    if (source.accessToken == null) {
      final actor = source.auth.currentUser?.id;
      isCurrent = () => source.auth.currentUser?.id == actor;
      if (!hasAuthorization && source.auth.currentSession?.isExpired == true) {
        await source.auth.refreshSession().timeout(budget);
      }
      if (!isCurrent()) throw StateError('REQUEST_ACTOR_CHANGED');
      final token = source.auth.currentSession?.accessToken;
      if (!hasAuthorization && token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    } else {
      if (!hasAuthorization) throw StateError('AUTH_SNAPSHOT_REQUIRED');
      isCurrent = () => true;
    }
    return AuthHttpSnapshot._(Map.unmodifiable(headers), isCurrent);
  }
}
