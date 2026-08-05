import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'bank_transfer_alert_message.dart';

class BankTransferAlertSoundService {
  static const _assetBasePath = 'assets/assets/audio/bank_transfer_vi';
  static const _tokenGap = 0.035;

  web.AudioContext? _context;
  final Map<String, web.AudioBuffer> _buffers = {};
  Future<bool>? _loadFuture;
  Future<void> _playbackQueue = Future.value();

  Future<void> prepare() async {
    await _prepareEmbeddedAudio();
  }

  Future<void> play({required int amount}) async {
    _playbackQueue = _playbackQueue
        .then((_) => _announce(amount))
        .catchError((_) {});
  }

  Future<void> _announce(int amount) async {
    try {
      if (await _prepareEmbeddedAudio()) {
        await _playEmbeddedAudio(amount);
        return;
      }
    } catch (_) {
      // Fall through to browser TTS if an asset cannot be decoded or played.
    }

    if (_speakWithBrowserTts(amount)) return;

    await _playFallbackTone();
  }

  Future<bool> _prepareEmbeddedAudio() async {
    try {
      final context = _context ??= web.AudioContext();
      if (context.state == 'suspended') {
        await context.resume().toDart;
      }
      if (_buffers.length == vietnameseBankTransferAudioAssetTokens.length) {
        return context.state == 'running';
      }
      return await (_loadFuture ??= _loadAudioAssets(context));
    } catch (_) {
      _loadFuture = null;
      return false;
    }
  }

  Future<bool> _loadAudioAssets(web.AudioContext context) async {
    for (final token in vietnameseBankTransferAudioAssetTokens) {
      final response = await web.window
          .fetch('$_assetBasePath/$token.mp3'.toJS)
          .toDart;
      if (!response.ok) return false;
      final bytes = await response.arrayBuffer().toDart;
      _buffers[token] = await context.decodeAudioData(bytes).toDart;
    }
    return context.state == 'running';
  }

  Future<void> _playEmbeddedAudio(int amount) async {
    final context = _context;
    if (context == null || context.state != 'running') return;

    var startsAt = context.currentTime + 0.02;
    for (final token in vietnameseBankTransferAudioTokens(amount)) {
      final buffer = _buffers[token];
      if (buffer == null) throw StateError('Missing audio token: $token');
      final source = context.createBufferSource()..buffer = buffer;
      source.connect(context.destination);
      source.start(startsAt);
      startsAt += buffer.duration + _tokenGap;
    }
    final playbackSeconds = startsAt - context.currentTime;
    await Future<void>.delayed(
      Duration(milliseconds: (playbackSeconds * 1000).ceil()),
    );
  }

  bool _speakWithBrowserTts(int amount) {
    try {
      final speech = web.window.speechSynthesis;
      final utterance =
          web.SpeechSynthesisUtterance(vietnameseBankTransferMessage(amount))
            ..lang = 'vi-VN'
            ..rate = 0.92
            ..pitch = 1
            ..volume = 1;
      speech.speak(utterance);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _playFallbackTone() async {
    final context = _context ??= web.AudioContext();
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }
    if (context.state != 'running') return;

    _scheduleTone(context, frequency: 880, offset: 0);
    _scheduleTone(context, frequency: 1175, offset: 0.17);
  }

  void _scheduleTone(
    web.AudioContext context, {
    required num frequency,
    required num offset,
  }) {
    final oscillator = context.createOscillator();
    final gain = context.createGain();
    final startsAt = context.currentTime + offset;
    final endsAt = startsAt + 0.14;

    oscillator.type = 'sine';
    oscillator.frequency.setValueAtTime(frequency, startsAt);
    gain.gain
      ..setValueAtTime(0.0001, startsAt)
      ..exponentialRampToValueAtTime(0.28, startsAt + 0.015)
      ..exponentialRampToValueAtTime(0.0001, endsAt);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(startsAt);
    oscillator.stop(endsAt);
  }
}

final bankTransferAlertSoundService = BankTransferAlertSoundService();
