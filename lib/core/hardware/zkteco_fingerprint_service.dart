import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fingerprint_service.dart';

bool get _isAndroid {
  if (kIsWeb) {
    return false;
  }
  try {
    return defaultTargetPlatform == TargetPlatform.android;
  } catch (_) {
    return false;
  }
}

FingerprintService createFingerprintService() {
  if (_isAndroid) {
    return ZKTecoFingerprintService();
  }
  return NoopFingerprintService();
}

class NoopFingerprintService implements FingerprintService {
  @override
  bool get isSupported => false;

  @override
  Future<String?> captureTemplate() async => null;

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> init() async => false;

  @override
  Future<bool> matchTemplate(String template1, String template2) async => false;
}

class ZKTecoFingerprintService implements FingerprintService {
  static const MethodChannel _channel = MethodChannel('zkfinger');

  bool _initialized = false;

  @override
  bool get isSupported => _isAndroid;

  @override
  Future<bool> init() async {
    try {
      final result = await _channel.invokeMethod<bool>('openConnection');
      _initialized = result ?? false;
      return _initialized;
    } catch (_) {
      _initialized = false;
      return false;
    }
  }

  @override
  Future<String?> captureTemplate() async {
    if (!_initialized) {
      return null;
    }

    try {
      final tempId = 'tmp_${DateTime.now().millisecondsSinceEpoch}';
      final enrolled = await _channel.invokeMethod<bool>(
        'register',
        <String, String>{'id': tempId},
      );
      if (enrolled != true) {
        return null;
      }
      final template = await _channel.invokeMethod<String>(
        'getUserFeature',
        <String, String>{'id': tempId},
      );
      await _channel.invokeMethod<bool>('delete', <String, String>{
        'id': tempId,
      });
      return template;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> matchTemplate(String template1, String template2) async {
    if (!_initialized) {
      return false;
    }

    try {
      final matched = await _channel.invokeMethod<bool>('verify', {
        'finger1': template1,
        'finger2': template2,
      });
      return matched ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<bool>('closeConnection');
      await _channel.invokeMethod<bool>('onDestroy');
    } catch (_) {}
    _initialized = false;
  }
}
