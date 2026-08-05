import 'package:flutter/services.dart';

class BankTransferAlertSoundService {
  Future<void> prepare() async {}

  Future<void> play({required int amount}) =>
      SystemSound.play(SystemSoundType.alert);
}

final bankTransferAlertSoundService = BankTransferAlertSoundService();
