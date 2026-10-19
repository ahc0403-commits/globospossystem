import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmergencyOutboxRecord {
  const EmergencyOutboxRecord({
    required this.id,
    required this.payload,
    this.createdAtEpochMs = 0,
  });

  final String id;
  final String payload;
  final int createdAtEpochMs;
}

class _EmergencyOutboxSnapshot {
  const _EmergencyOutboxSnapshot({
    required this.records,
    required this.generation,
  });

  final List<EmergencyOutboxRecord> records;
  final int generation;
}

abstract final class EmergencyWebBridge {
  static const _primaryKey = 'kds_command_outbox_v2';
  static const _backupKey = 'kds_command_outbox_backup_v2';
  static const _schemaVersion = 2;
  static const _maximumRecords = 1000;
  static Future<void> _operationTail = Future<void>.value();

  static Future<bool> enableVoice() async => false;
  static Future<bool> speak(String message) async => false;

  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operationTail;
    final result = Completer<T>();
    _operationTail = () async {
      try {
        await previous;
      } catch (_) {}
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }

  static Future<void> putOutbox(String id, String payload) => _serialized(
    () async {
      _validatePayload(id, payload);
      final snapshot = await _readUnlocked();
      final next = snapshot.records.where((record) => record.id != id).toList();
      if (next.length >= _maximumRecords) {
        throw StateError('KDS_OUTBOX_CAPACITY_EXCEEDED');
      }
      next.add(
        EmergencyOutboxRecord(
          id: id,
          payload: payload,
          createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _writeUnlocked(next, generation: snapshot.generation + 1);
    },
  );

  static Future<List<EmergencyOutboxRecord>> readOutbox() => _serialized(
    () async => List.unmodifiable((await _readUnlocked()).records),
  );

  static Future<void> deleteOutbox(String id) => _serialized(() async {
    final snapshot = await _readUnlocked();
    await _writeUnlocked(
      snapshot.records
          .where((record) => record.id != id)
          .toList(growable: false),
      generation: snapshot.generation + 1,
    );
  });

  static Future<_EmergencyOutboxSnapshot> _readUnlocked() async {
    final preferences = await SharedPreferences.getInstance();
    Object? primaryError;
    Object? backupError;
    _EmergencyOutboxSnapshot? primary;
    _EmergencyOutboxSnapshot? backup;
    try {
      primary = _decode(preferences.getString(_primaryKey));
    } catch (error) {
      primaryError = error;
    }
    try {
      backup = _decode(preferences.getString(_backupKey));
    } catch (error) {
      backupError = error;
    }
    if (primary != null && backup != null) {
      return primary.generation >= backup.generation ? primary : backup;
    }
    if (primary != null) return primary;
    if (backup != null) return backup;
    if (primaryError != null || backupError != null) {
      throw FormatException(
        'KDS_OUTBOX_CORRUPT: primary=$primaryError; backup=$backupError',
      );
    }
    return const _EmergencyOutboxSnapshot(records: [], generation: 0);
  }

  static _EmergencyOutboxSnapshot? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid KDS outbox root');
    final envelope = Map<String, dynamic>.from(decoded);
    final generation = envelope['generation'];
    if (envelope['version'] != _schemaVersion ||
        generation is! int ||
        generation < 1 ||
        envelope['records'] is! List) {
      throw const FormatException('Invalid KDS outbox envelope');
    }
    final records = List<dynamic>.from(envelope['records'] as List);
    if (records.length > _maximumRecords) {
      throw const FormatException('KDS outbox exceeds capacity');
    }
    final checksum = envelope['checksum'];
    if (checksum is! String ||
        checksum != _checksum(records, generation: generation)) {
      throw const FormatException('KDS outbox checksum mismatch');
    }
    final ids = <String>{};
    final decodedRecords =
        records
            .map((rawRecord) {
              if (rawRecord is! Map) {
                throw const FormatException('Invalid KDS outbox record');
              }
              final record = Map<String, dynamic>.from(rawRecord);
              final id = record['id'];
              final payload = record['payload'];
              final createdAt = record['createdAt'];
              if (id is! String ||
                  !ids.add(id) ||
                  payload is! String ||
                  createdAt is! int) {
                throw const FormatException('Invalid KDS outbox record fields');
              }
              _validatePayload(id, payload);
              return EmergencyOutboxRecord(
                id: id,
                payload: payload,
                createdAtEpochMs: createdAt,
              );
            })
            .toList(growable: false)
          ..sort(
            (left, right) =>
                left.createdAtEpochMs.compareTo(right.createdAtEpochMs),
          );
    return _EmergencyOutboxSnapshot(
      records: decodedRecords,
      generation: generation,
    );
  }

  static void _validatePayload(String id, String payload) {
    if (id.trim().isEmpty) throw const FormatException('Empty outbox id');
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException('Invalid KDS outbox payload');
    }
  }

  static String _checksum(List<dynamic> records, {required int generation}) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'version': _schemaVersion,
                'generation': generation,
                'records': records,
              }),
            ),
          )
          .toString();

  static Future<void> _writeUnlocked(
    List<EmergencyOutboxRecord> records, {
    required int generation,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final rawRecords = records
        .map(
          (record) => {
            'id': record.id,
            'payload': record.payload,
            'createdAt': record.createdAtEpochMs,
          },
        )
        .toList(growable: false);
    final encoded = jsonEncode({
      'version': _schemaVersion,
      'generation': generation,
      'records': rawRecords,
      'checksum': _checksum(rawRecords, generation: generation),
    });
    if (!await preferences.setString(_backupKey, encoded) ||
        !await preferences.setString(_primaryKey, encoded)) {
      throw StateError('KDS_OUTBOX_WRITE_FAILED');
    }
  }

  static Future<bool> configurePushWorker(String firebaseConfigJson) async =>
      false;
}
