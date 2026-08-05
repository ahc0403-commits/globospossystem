import 'package:flutter/services.dart';

class BankTransferAlertSoundService {
  Future<void> prepare() async {}

  Future<void> play() => SystemSound.play(SystemSoundType.alert);
}

final bankTransferAlertSoundService = BankTransferAlertSoundService();
