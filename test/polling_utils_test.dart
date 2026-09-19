import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/polling_utils.dart';

void main() {
  test('jitter stays inside the configured window', () {
    final random = Random(42);
    final samples = [
      for (var i = 0; i < 1000; i++)
        jitteredPollDelay(
          const Duration(seconds: 30),
          maximumJitter: const Duration(seconds: 5),
          random: random,
        ),
    ];

    expect(
      samples.every(
        (delay) =>
            delay >= const Duration(seconds: 25) &&
            delay <= const Duration(seconds: 35),
      ),
      isTrue,
    );
    expect(samples.toSet().length, greaterThan(100));
  });

  test('very short intervals never become zero or negative', () {
    expect(
      jitteredPollDelay(const Duration(milliseconds: 2), random: Random(1)),
      greaterThan(Duration.zero),
    );
  });
}
