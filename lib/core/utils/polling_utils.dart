import 'dart:math' as math;

final math.Random _pollJitterRandom = math.Random();

/// Spreads safety reads across devices so reconnects and store opening do not
/// align thousands of requests on the same second.
Duration jitteredPollDelay(
  Duration interval, {
  Duration maximumJitter = const Duration(seconds: 5),
  math.Random? random,
}) {
  final baseMs = interval.inMilliseconds;
  if (baseMs <= 1) return const Duration(milliseconds: 1);
  final jitterMs = math.min(maximumJitter.inMilliseconds, baseMs - 1);
  if (jitterMs <= 0) return interval;
  final source = random ?? _pollJitterRandom;
  final offset = source.nextInt((jitterMs * 2) + 1) - jitterMs;
  return Duration(milliseconds: math.max(1, baseMs + offset));
}
