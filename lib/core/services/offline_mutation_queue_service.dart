import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineQueueCorruptionException implements Exception {
  const OfflineQueueCorruptionException(this.message);

  final String message;

  @override
  String toString() => 'OfflineQueueCorruptionException: $message';
}

class OfflineQueueStorageException implements Exception {
  const OfflineQueueStorageException(this.message);

  final String message;

  @override
  String toString() => 'OfflineQueueStorageException: $message';
}

class OfflineQueueCapacityException implements Exception {
  const OfflineQueueCapacityException(this.maximum);

  final int maximum;

  @override
  String toString() =>
      'OfflineQueueCapacityException: queue limit of $maximum reached';
}

class QueuedMutation {
  const QueuedMutation({
    required this.id,
    required this.type,
    required this.storeId,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
  });

  final String id;
  final String type;
  final String storeId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;

  QueuedMutation copyWith({int? attempts, String? lastError}) {
    return QueuedMutation(
      id: id,
      type: type,
      storeId: storeId,
      payload: payload,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'storeId': storeId,
    'payload': payload,
    'createdAt': createdAt.toIso8601String(),
    'attempts': attempts,
    if (lastError != null) 'lastError': lastError,
  };

  factory QueuedMutation.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final type = json['type'];
    final storeId = json['storeId'];
    final payload = json['payload'];
    final createdAtValue = json['createdAt'];
    final attemptsValue = json['attempts'] ?? 0;

    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Queued mutation id is missing.');
    }
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException('Queued mutation type is missing.');
    }
    if (storeId is! String || storeId.trim().isEmpty) {
      throw const FormatException('Queued mutation storeId is missing.');
    }
    if (payload is! Map) {
      throw const FormatException('Queued mutation payload is invalid.');
    }
    if (createdAtValue is! String ||
        DateTime.tryParse(createdAtValue) == null) {
      throw const FormatException('Queued mutation createdAt is invalid.');
    }
    if (attemptsValue is! num ||
        attemptsValue.toInt() != attemptsValue ||
        attemptsValue < 0) {
      throw const FormatException('Queued mutation attempts is invalid.');
    }
    if (json['lastError'] != null && json['lastError'] is! String) {
      throw const FormatException('Queued mutation lastError is invalid.');
    }

    return QueuedMutation(
      id: id,
      type: type,
      storeId: storeId,
      payload: Map<String, dynamic>.from(payload),
      createdAt: DateTime.parse(createdAtValue),
      attempts: attemptsValue.toInt(),
      lastError: json['lastError'] as String?,
    );
  }
}

class _QueueSnapshot {
  const _QueueSnapshot({required this.records, required this.generation});

  final List<QueuedMutation> records;
  final int generation;
}

class _DecodedQueueCopy {
  const _DecodedQueueCopy({
    required this.source,
    required this.snapshot,
    this.error,
  });

  final String source;
  final _QueueSnapshot? snapshot;
  final Object? error;

  bool get isAbsent => snapshot == null && error == null;
  bool get isCorrupt => error != null;
}

class OfflineMutationQueueService {
  OfflineMutationQueueService({SharedPreferences? preferences})
    : _preferences = preferences;

  static const createOrderType = 'create_order';
  static const addItemsToOrderType = 'add_items_to_order';
  static const _queueKey = 'pos_offline_mutation_queue_v1';
  static const _backupKey = 'pos_offline_mutation_queue_backup_v2';
  static const _schemaVersion = 2;
  static const _maximumQueueItems = 1000;

  final SharedPreferences? _preferences;
  Future<void> _operationTail = Future<void>.value();

  /// Non-null when one durable copy was damaged but the other copy recovered
  /// the queue. The next successful mutation rewrites both copies.
  String? lastRecoveryWarning;

  Future<SharedPreferences> _prefs() async {
    return _preferences ?? SharedPreferences.getInstance();
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operationTail;
    final result = Completer<T>();
    _operationTail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed operation must not permanently block later queue access.
      }
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }

  Future<List<QueuedMutation>> list() =>
      _serialized(() async => List.unmodifiable((await _read()).records));

  Future<int> pendingCount() =>
      _serialized(() async => (await _read()).records.length);

  Future<void> enqueue(QueuedMutation mutation) => _serialized(() async {
    final snapshot = await _read();
    final withoutDuplicate = snapshot.records
        .where((entry) => entry.id != mutation.id)
        .toList();
    if (withoutDuplicate.length >= _maximumQueueItems) {
      throw const OfflineQueueCapacityException(_maximumQueueItems);
    }
    withoutDuplicate.add(mutation);
    await _write(withoutDuplicate, generation: snapshot.generation + 1);
  });

  Future<void> remove(String id) => _serialized(() async {
    final snapshot = await _read();
    await _write(
      snapshot.records.where((entry) => entry.id != id).toList(),
      generation: snapshot.generation + 1,
    );
  });

  Future<void> markFailed(String id, Object error) => _serialized(() async {
    final snapshot = await _read();
    await _write(
      snapshot.records.map((entry) {
        if (entry.id != id) {
          return entry;
        }
        return entry.copyWith(
          attempts: entry.attempts + 1,
          lastError: error.toString(),
        );
      }).toList(),
      generation: snapshot.generation + 1,
    );
  });

  Future<_QueueSnapshot> _read() async {
    final prefs = await _prefs();
    final primary = _decodeCopy('primary', prefs.getString(_queueKey));
    final backup = _decodeCopy('backup', prefs.getString(_backupKey));
    final valid = [
      if (primary.snapshot != null) primary,
      if (backup.snapshot != null) backup,
    ];

    if (valid.isEmpty) {
      if (primary.isAbsent && backup.isAbsent) {
        lastRecoveryWarning = null;
        return const _QueueSnapshot(records: [], generation: 0);
      }
      final reasons = [primary, backup]
          .where((copy) => copy.isCorrupt)
          .map((copy) => '${copy.source}: ${copy.error}')
          .join('; ');
      throw OfflineQueueCorruptionException(
        'No valid queue copy is available ($reasons).',
      );
    }

    valid.sort(
      (left, right) =>
          right.snapshot!.generation.compareTo(left.snapshot!.generation),
    );
    final recovered = valid.first.snapshot!;
    final corruptCopies = [
      primary,
      backup,
    ].where((copy) => copy.isCorrupt).map((copy) => copy.source).join(', ');
    lastRecoveryWarning = corruptCopies.isEmpty
        ? null
        : 'Recovered queue generation ${recovered.generation} from the '
              'remaining durable copy; damaged copy: $corruptCopies.';
    return recovered;
  }

  _DecodedQueueCopy _decodeCopy(String source, String? raw) {
    if (raw == null || raw.isEmpty) {
      return _DecodedQueueCopy(source: source, snapshot: null);
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return _DecodedQueueCopy(
          source: source,
          snapshot: _QueueSnapshot(
            records: _decodeRecords(decoded),
            generation: 0,
          ),
        );
      }

      if (decoded is! Map) {
        throw const FormatException('Queue root must be an object or list.');
      }
      final envelope = Map<String, dynamic>.from(decoded);
      if (envelope['version'] != _schemaVersion) {
        throw FormatException(
          'Unsupported queue schema version ${envelope['version']}.',
        );
      }
      final generation = envelope['generation'];
      final records = envelope['records'];
      final checksum = envelope['checksum'];
      if (generation is! int || generation < 1) {
        throw const FormatException('Queue generation is invalid.');
      }
      if (records is! List || checksum is! String) {
        throw const FormatException('Queue envelope is incomplete.');
      }
      final expectedChecksum = _checksum(
        generation: generation,
        records: records,
      );
      if (checksum != expectedChecksum) {
        throw const FormatException('Queue checksum does not match.');
      }
      return _DecodedQueueCopy(
        source: source,
        snapshot: _QueueSnapshot(
          records: _decodeRecords(records),
          generation: generation,
        ),
      );
    } catch (error) {
      return _DecodedQueueCopy(source: source, snapshot: null, error: error);
    }
  }

  List<QueuedMutation> _decodeRecords(List<dynamic> records) {
    if (records.length > _maximumQueueItems) {
      throw const FormatException('Queue exceeds the supported item limit.');
    }
    final decoded = <QueuedMutation>[];
    final ids = <String>{};
    for (final rawRecord in records) {
      if (rawRecord is! Map) {
        throw const FormatException('Queue contains an invalid record.');
      }
      final mutation = QueuedMutation.fromJson(
        Map<String, dynamic>.from(rawRecord),
      );
      if (!ids.add(mutation.id)) {
        throw FormatException('Queue contains duplicate id ${mutation.id}.');
      }
      decoded.add(mutation);
    }
    return decoded;
  }

  String _checksum({required int generation, required List records}) {
    final canonical = jsonEncode({
      'version': _schemaVersion,
      'generation': generation,
      'records': records,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  Future<void> _write(
    List<QueuedMutation> queue, {
    required int generation,
  }) async {
    final prefs = await _prefs();
    final records = queue.map((entry) => entry.toJson()).toList();
    final encoded = jsonEncode({
      'version': _schemaVersion,
      'generation': generation,
      'records': records,
      'checksum': _checksum(generation: generation, records: records),
    });

    if (!await prefs.setString(_backupKey, encoded)) {
      throw const OfflineQueueStorageException(
        'Failed to write the backup queue copy.',
      );
    }
    if (!await prefs.setString(_queueKey, encoded)) {
      throw const OfflineQueueStorageException(
        'Failed to write the primary queue copy.',
      );
    }
    lastRecoveryWarning = null;
  }
}

final offlineMutationQueueService = OfflineMutationQueueService();
