import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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
    return QueuedMutation(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      storeId: json['storeId']?.toString() ?? '',
      payload: Map<String, dynamic>.from(json['payload'] as Map? ?? const {}),
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      attempts: switch (json['attempts']) {
        int value => value,
        num value => value.toInt(),
        _ => 0,
      },
      lastError: json['lastError']?.toString(),
    );
  }
}

class OfflineMutationQueueService {
  OfflineMutationQueueService({SharedPreferences? preferences})
    : _preferences = preferences;

  static const createOrderType = 'create_order';
  static const addItemsToOrderType = 'add_items_to_order';
  static const _queueKey = 'pos_offline_mutation_queue_v1';

  final SharedPreferences? _preferences;

  Future<SharedPreferences> _prefs() async {
    return _preferences ?? SharedPreferences.getInstance();
  }

  Future<List<QueuedMutation>> list() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.isEmpty) {
      return const <QueuedMutation>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <QueuedMutation>[];
      }
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                QueuedMutation.fromJson(Map<String, dynamic>.from(entry)),
          )
          .where((entry) => entry.id.isNotEmpty && entry.type.isNotEmpty)
          .toList();
    } catch (_) {
      return const <QueuedMutation>[];
    }
  }

  Future<int> pendingCount() async => (await list()).length;

  Future<void> enqueue(QueuedMutation mutation) async {
    final queue = await list();
    final withoutDuplicate = queue
        .where((entry) => entry.id != mutation.id)
        .toList();
    withoutDuplicate.add(mutation);
    await _write(withoutDuplicate);
  }

  Future<void> remove(String id) async {
    final queue = await list();
    await _write(queue.where((entry) => entry.id != id).toList());
  }

  Future<void> markFailed(String id, Object error) async {
    final queue = await list();
    await _write(
      queue.map((entry) {
        if (entry.id != id) {
          return entry;
        }
        return entry.copyWith(
          attempts: entry.attempts + 1,
          lastError: error.toString(),
        );
      }).toList(),
    );
  }

  Future<void> _write(List<QueuedMutation> queue) async {
    final prefs = await _prefs();
    await prefs.setString(
      _queueKey,
      jsonEncode(queue.map((entry) => entry.toJson()).toList()),
    );
  }
}

final offlineMutationQueueService = OfflineMutationQueueService();
