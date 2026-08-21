import 'dart:js_interop';

import 'package:web/web.dart' as web;

class DirectOrderArrivalAlertSoundService {
  web.AudioContext? _context;

  Future<void> prepare() async {
    final context = _context ??= web.AudioContext();
    if (context.state == 'suspended') await context.resume().toDart;
  }

  Future<void> play() async {
    await prepare();
    final context = _context;
    if (context == null || context.state != 'running') return;
    _tone(context, frequency: 740, offset: 0);
    _tone(context, frequency: 988, offset: 0.16);
  }

  void _tone(
    web.AudioContext context, {
    required num frequency,
    required num offset,
  }) {
    final oscillator = context.createOscillator();
    final gain = context.createGain();
    final startsAt = context.currentTime + offset;
    final endsAt = startsAt + 0.13;
    oscillator.type = 'sine';
    oscillator.frequency.setValueAtTime(frequency, startsAt);
    gain.gain
      ..setValueAtTime(0.0001, startsAt)
      ..exponentialRampToValueAtTime(0.22, startsAt + 0.015)
      ..exponentialRampToValueAtTime(0.0001, endsAt);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(startsAt);
    oscillator.stop(endsAt);
  }
}

final directOrderArrivalAlertSoundService =
    DirectOrderArrivalAlertSoundService();
