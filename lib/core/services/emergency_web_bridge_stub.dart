class EmergencyOutboxRecord {
  const EmergencyOutboxRecord({required this.id, required this.payload});

  final String id;
  final String payload;
}

abstract final class EmergencyWebBridge {
  static Future<bool> enableAlarm() async => true;
  static Future<void> playAlarm() async {}
  static Future<void> putOutbox(String id, String payload) async {}
  static Future<List<EmergencyOutboxRecord>> readOutbox() async => const [];
  static Future<void> deleteOutbox(String id) async {}
  static Future<bool> configurePushWorker(String firebaseConfigJson) async =>
      false;
}
