import 'dart:convert';
import 'dart:js_interop';

class EmergencyOutboxRecord {
  const EmergencyOutboxRecord({required this.id, required this.payload});

  final String id;
  final String payload;
}

@JS('globosEmergencyVoiceEnable')
external JSBoolean _enableVoice();

@JS('globosEmergencyVoiceSpeak')
external JSBoolean _speakVoice(JSString message);

@JS('globosEmergencyOutboxPut')
external JSPromise<JSAny?> _putOutbox(JSString id, JSString payload);

@JS('globosEmergencyOutboxReadAll')
external JSPromise<JSString> _readOutbox();

@JS('globosEmergencyOutboxDelete')
external JSPromise<JSAny?> _deleteOutbox(JSString id);

@JS('globosEmergencyConfigurePushWorker')
external JSPromise<JSBoolean> _configurePushWorker(JSString configJson);

abstract final class EmergencyWebBridge {
  static Future<bool> enableVoice() async => _enableVoice().toDart;

  static Future<bool> speak(String message) async =>
      _speakVoice(message.toJS).toDart;

  static Future<void> putOutbox(String id, String payload) async {
    await _putOutbox(id.toJS, payload.toJS).toDart;
  }

  static Future<List<EmergencyOutboxRecord>> readOutbox() async {
    final raw = await _readOutbox().toDart;
    final decoded = jsonDecode(raw.toDart);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .map(
          (row) => EmergencyOutboxRecord(
            id: row['id']?.toString() ?? '',
            payload: row['payload']?.toString() ?? '{}',
          ),
        )
        .where((record) => record.id.isNotEmpty)
        .toList(growable: false);
  }

  static Future<void> deleteOutbox(String id) async {
    await _deleteOutbox(id.toJS).toDart;
  }

  static Future<bool> configurePushWorker(String firebaseConfigJson) async =>
      (await _configurePushWorker(firebaseConfigJson.toJS).toDart).toDart;
}
