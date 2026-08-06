import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'bank_transfer_alert_message.dart';

class BankTransferAlertSoundService {
  static const _assetDirectory = 'audio/bank_transfer_vi';

  AudioPlayer? _player;
  Future<void> _playbackQueue = Future.value();
  Future<bool>? _prepareFuture;

  Future<void> prepare() async {
    await (_prepareFuture ??= _preparePlayer());
  }

  Future<void> play({required int amount}) async {
    _playbackQueue = _playbackQueue
        .then((_) => _announce(amount))
        .catchError((_) {});
  }

  Future<bool> _preparePlayer() async {
    try {
      final player = _player ??= AudioPlayer();
      await player.setReleaseMode(ReleaseMode.stop);
      await player.audioCache.loadAll(
        vietnameseBankTransferAudioAssetTokens
            .map((token) => '$_assetDirectory/$token.mp3')
            .toList(),
      );
      return true;
    } catch (_) {
      _prepareFuture = null;
      return false;
    }
  }

  Future<void> _announce(int amount) async {
    try {
      if (!await (_prepareFuture ??= _preparePlayer())) {
        throw StateError('Vietnamese audio assets are unavailable');
      }
      final player = _player;
      if (player == null) throw StateError('Audio player is unavailable');

      for (final token in vietnameseBankTransferAudioTokens(amount)) {
        final completed = player.onPlayerComplete.first;
        await player.play(AssetSource('$_assetDirectory/$token.mp3'));
        await completed.timeout(const Duration(seconds: 3));
      }
      return;
    } catch (_) {
      // Keep an audible system alert if native asset playback fails.
    }

    await SystemSound.play(SystemSoundType.alert);
  }
}

final bankTransferAlertSoundService = BankTransferAlertSoundService();
