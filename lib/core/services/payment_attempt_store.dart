import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

class PaymentAttemptScope {
  const PaymentAttemptScope({
    required this.actorAuthId,
    required this.storeId,
    required this.orderId,
    required this.splitIndex,
    required this.method,
    required this.amount,
  });

  final String actorAuthId;
  final String storeId;
  final String orderId;
  final int splitIndex;
  final String method;
  final num amount;

  String get storageScope {
    final canonical = <String>[
      'v2',
      actorAuthId,
      storeId,
      orderId,
      splitIndex.toString(),
      method.trim().toUpperCase(),
      amount.toStringAsFixed(2),
    ].join('|');
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

class PaymentAttemptStore {
  PaymentAttemptStore({
    PreferencesLoader? preferences,
    DateTime Function()? now,
    String Function()? idFactory,
    this.maxEntries = 500,
    this.maxAge = const Duration(days: 7),
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v4;

  static const preferenceKey = 'payment_attempt_ids_v2';

  final PreferencesLoader _preferences;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final int maxEntries;
  final Duration maxAge;
  Future<void> _operation = Future<void>.value();

  Future<String> getOrCreate(PaymentAttemptScope scope) {
    return _synchronized(() async {
      final preferences = await _preferences();
      final entries = _read(preferences);
      final now = _now().toUtc();
      final active = _activeEntries(entries, now);
      final scopeKey = scope.storageScope;
      for (final entry in active) {
        if (entry.scope == scopeKey) {
          if (active.length != entries.length) {
            await _write(preferences, active);
          }
          return entry.attemptId;
        }
      }

      if (active.length >= maxEntries) {
        active.removeLast();
      }
      active.add(
        _PaymentAttemptEntry(
          scope: scopeKey,
          attemptId: _idFactory(),
          createdAt: now,
        ),
      );
      active.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final bounded = active.take(maxEntries).toList(growable: false);
      await _write(preferences, bounded);
      return bounded.firstWhere((entry) => entry.scope == scopeKey).attemptId;
    });
  }

  Future<void> clear(PaymentAttemptScope scope) async {
    await clearMany([scope]);
  }

  Future<void> clearMany(Iterable<PaymentAttemptScope> scopes) {
    return _synchronized(() async {
      final preferences = await _preferences();
      final keys = scopes.map((scope) => scope.storageScope).toSet();
      final remaining = _read(
        preferences,
      ).where((entry) => !keys.contains(entry.scope)).toList(growable: false);
      await _write(preferences, remaining);
    });
  }

  Future<void> cleanup() {
    return _synchronized(() async {
      final preferences = await _preferences();
      await _write(
        preferences,
        _activeEntries(_read(preferences), _now().toUtc()),
      );
    });
  }

  Future<int> debugEntryCount() {
    return _synchronized(() async {
      final preferences = await _preferences();
      return _read(preferences).length;
    });
  }

  Future<T> _synchronized<T>(Future<T> Function() callback) {
    final completer = Completer<T>();
    _operation = _operation.then((_) async {
      try {
        completer.complete(await callback());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  List<_PaymentAttemptEntry> _activeEntries(
    List<_PaymentAttemptEntry> entries,
    DateTime now,
  ) {
    final cutoff = now.subtract(maxAge);
    final active = entries
        .where((entry) => !entry.createdAt.isBefore(cutoff))
        .toList();
    active.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return active.take(maxEntries).toList(growable: true);
  }

  List<_PaymentAttemptEntry> _read(SharedPreferences preferences) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return <_PaymentAttemptEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <_PaymentAttemptEntry>[];
      return decoded
          .whereType<Map>()
          .map((item) => _PaymentAttemptEntry.tryParse(item))
          .whereType<_PaymentAttemptEntry>()
          .toList();
    } on FormatException {
      return <_PaymentAttemptEntry>[];
    }
  }

  Future<void> _write(
    SharedPreferences preferences,
    List<_PaymentAttemptEntry> entries,
  ) async {
    if (entries.isEmpty) {
      await preferences.remove(preferenceKey);
      return;
    }
    await preferences.setString(
      preferenceKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }
}

class _PaymentAttemptEntry {
  const _PaymentAttemptEntry({
    required this.scope,
    required this.attemptId,
    required this.createdAt,
  });

  final String scope;
  final String attemptId;
  final DateTime createdAt;

  static _PaymentAttemptEntry? tryParse(Map<dynamic, dynamic> json) {
    final scope = json['scope']?.toString();
    final attemptId = json['attempt_id']?.toString();
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    if (scope == null ||
        scope.length != 64 ||
        attemptId == null ||
        attemptId.isEmpty ||
        createdAt == null) {
      return null;
    }
    return _PaymentAttemptEntry(
      scope: scope,
      attemptId: attemptId,
      createdAt: createdAt.toUtc(),
    );
  }

  Map<String, String> toJson() => <String, String>{
    'scope': scope,
    'attempt_id': attemptId,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
