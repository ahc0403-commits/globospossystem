import 'package:flutter/services.dart';

class DirectOrderArrivalAlertSoundService {
  Future<void> prepare() async {}

  Future<void> play() async {
    await SystemSound.play(SystemSoundType.alert);
  }
}

final directOrderArrivalAlertSoundService =
    DirectOrderArrivalAlertSoundService();
