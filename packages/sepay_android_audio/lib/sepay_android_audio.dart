import 'package:flutter/services.dart';

class SePayAndroidAudio {
  SePayAndroidAudio._();

  static const _channel = MethodChannel('com.globosvn/sepay_android_audio');

  static Future<bool> announce(List<String> tokens) async {
    if (tokens.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('announce', {
            'tokens': tokens,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
