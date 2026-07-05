import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const providers = {
    'order_provider': 'lib/features/order/order_provider.dart',
    'kitchen_provider': 'lib/features/kitchen/kitchen_provider.dart',
    'table_provider': 'lib/features/table/table_provider.dart',
    'payment_provider': 'lib/features/payment/payment_provider.dart',
    'admin/tables_provider': 'lib/features/admin/providers/tables_provider.dart',
  };

  group('poll guard: _ensureAutoRefresh checks _realtimeConnected', () {
    for (final entry in providers.entries) {
      test('${entry.key} cancels timer when realtime connected', () {
        final content = File(entry.value).readAsStringSync();

        final ensureBody = _extractEnsureAutoRefreshBody(content);
        expect(
          ensureBody,
          isNotNull,
          reason: '${entry.key} must have _ensureAutoRefresh method',
        );

        expect(
          ensureBody,
          contains('_realtimeConnected'),
          reason:
              '${entry.key} _ensureAutoRefresh must check _realtimeConnected',
        );

        expect(
          ensureBody,
          contains('_pollTimer?.cancel()'),
          reason:
              '${entry.key} must cancel poll timer when realtime is connected',
        );
      });
    }
  });

  group('poll guard: fallback interval is >= 10s', () {
    for (final entry in providers.entries) {
      test('${entry.key} uses _fallbackPollInterval', () {
        final content = File(entry.value).readAsStringSync();
        expect(
          content,
          contains('_fallbackPollInterval'),
          reason: '${entry.key} must use _fallbackPollInterval for polling',
        );
      });

      test('${entry.key} fallback interval >= 10 seconds', () {
        final content = File(entry.value).readAsStringSync();
        final match =
            RegExp(r'_fallbackPollInterval\s*=\s*Duration\(seconds:\s*(\d+)\)')
                .firstMatch(content);
        expect(match, isNotNull, reason: '${entry.key} must define interval');
        final seconds = int.parse(match!.group(1)!);
        expect(
          seconds,
          greaterThanOrEqualTo(10),
          reason: 'Fallback poll interval must be >= 10s (was ${seconds}s)',
        );
      });
    }
  });

  group('poll guard: no Timer.periodic with Duration(seconds: 2)', () {
    for (final entry in providers.entries) {
      test('${entry.key} has no 2-second periodic timer', () {
        final content = File(entry.value).readAsStringSync();
        final twoSecondTimer = RegExp(
          r'Timer\.periodic\(\s*_autoRefreshInterval',
        );
        expect(
          twoSecondTimer.hasMatch(content),
          isFalse,
          reason:
              '${entry.key} must not use _autoRefreshInterval in Timer.periodic',
        );
      });
    }
  });
}

String? _extractEnsureAutoRefreshBody(String content) {
  final start = content.indexOf('void _ensureAutoRefresh(');
  if (start == -1) return null;

  var braceCount = 0;
  var bodyStart = content.indexOf('{', start);
  if (bodyStart == -1) return null;

  for (var i = bodyStart; i < content.length; i++) {
    if (content[i] == '{') braceCount++;
    if (content[i] == '}') braceCount--;
    if (braceCount == 0) {
      return content.substring(bodyStart, i + 1);
    }
  }
  return null;
}
