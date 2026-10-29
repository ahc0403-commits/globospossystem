import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final session = DirectOrderSession(
    id: 'session',
    secret: 'secret',
    expiresAt: DateTime.utc(2099),
    orderScoped: true,
  );
  final payload = <String, dynamic>{
    'existing': [
      {'id': 'line', 'quantity': 2},
    ],
    'additions': [],
  };
  test(
    'lost response retries the same operation after recreating the service',
    () async {
      final calls = <Map<String, dynamic>>[];
      final first = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          throw const DirectOrderException(
            'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
          );
        },
      );
      await expectLater(
        first.amend(
          session: session,
          requestId: 'order',
          token: 'token',
          payload: payload,
        ),
        throwsA(isA<DirectOrderException>()),
      );
      final second = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          return {'request_id': 'order', 'state': 'awaiting_quote'};
        },
      );
      await second.amend(
        session: session,
        requestId: 'order',
        token: 'token',
        payload: payload,
      );
      expect(calls[0], calls[1]);
      expect(calls[1]['order_scoped'], true);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.containsKey('direct_order_pending_amendment_order'),
        false,
      );
    },
  );
  test(
    'uncertain operation cannot silently accept a different payload',
    () async {
      var calls = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          calls++;
          throw const DirectOrderException(
            'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
          );
        },
      );
      await expectLater(
        service.amend(
          session: session,
          requestId: 'order',
          token: 'old',
          payload: payload,
        ),
        throwsA(isA<DirectOrderException>()),
      );
      await expectLater(
        service.amend(
          session: session,
          requestId: 'order',
          token: 'new',
          payload: payload,
        ),
        throwsA(
          isA<DirectOrderException>().having(
            (e) => e.code,
            'code',
            'DIRECT_ORDER_AMENDMENT_RETRY_CHANGED',
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'definitive stale response clears the attempt for a fresh edit',
    () async {
      final service = DirectOrderService(
        invoker: (_) async {
          throw const DirectOrderException('DIRECT_ORDER_AMENDMENT_STALE');
        },
      );
      await expectLater(
        service.amend(
          session: session,
          requestId: 'order',
          token: 'old',
          payload: payload,
        ),
        throwsA(isA<DirectOrderException>()),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.containsKey('direct_order_pending_amendment_order'),
        false,
      );
    },
  );
}
