import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/navigation_history_service.dart';

void main() {
  test(
    'app navigation history preserves forward stack after back navigation',
    () {
      final nav = NavigationHistoryService.instance;
      nav.clear();

      nav.push('/waiter');
      nav.push('/cashier');
      nav.push('/payments/payment-1');

      expect(nav.goBack(), '/cashier');
      nav.push('/cashier');

      expect(nav.canGoForward, isTrue);
      expect(nav.goForward(), '/payments/payment-1');

      nav.clear();
    },
  );
}
