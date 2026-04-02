abstract class FingerprintService {
  Future<bool> init();
  Future<String?> captureTemplate();
  Future<bool> matchTemplate(String template1, String template2);
  Future<void> dispose();
  bool get isSupported;
}
