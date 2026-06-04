import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';

void main() {
  group('canAccessRouteForRole', () {
    test('blocks staff from other operational workspaces', () {
      expect(canAccessRouteForRole('waiter', '/cashier'), isFalse);
      expect(canAccessRouteForRole('cashier', '/waiter'), isFalse);
      expect(canAccessRouteForRole('kitchen', '/cashier'), isFalse);
    });

    test('keeps each staff role on its own workspace', () {
      expect(canAccessRouteForRole('waiter', '/waiter'), isTrue);
      expect(canAccessRouteForRole('cashier', '/cashier'), isTrue);
      expect(canAccessRouteForRole('kitchen', '/kitchen'), isTrue);
    });

    test('normalizes query-string deep links before checking access', () {
      expect(canAccessRouteForRole('store_admin', '/admin?tab=qc'), isTrue);
      expect(
        canAccessRouteForRole('super_admin', '/admin/store-1?tab=einvoice'),
        isTrue,
      );
      expect(canAccessRouteForRole('cashier', '/payments/payment-1'), isTrue);
      expect(canAccessRouteForRole('waiter', '/payments/payment-1'), isFalse);
    });

    test('blocks dormant attendance kiosk route for logged-in roles', () {
      const roles = [
        'super_admin',
        'photo_objet_master',
        'photo_objet_store_admin',
        'brand_admin',
        'store_admin',
        'admin',
        'waiter',
        'cashier',
        'kitchen',
      ];

      for (final role in roles) {
        expect(
          canAccessRouteForRole(role, '/attendance-kiosk'),
          isFalse,
          reason: 'attendance kiosk is dormant and disabled for role=$role',
        );
      }
    });

    test('keeps photo objet roles out of general POS workspaces', () {
      expect(canAccessRouteForRole('photo_objet_master', '/photo-ops'), isTrue);
      expect(
        canAccessRouteForRole('photo_objet_store_admin', '/photo-ops'),
        isTrue,
      );
      expect(canAccessRouteForRole('photo_objet_master', '/cashier'), isFalse);
      expect(
        canAccessRouteForRole('photo_objet_store_admin', '/admin'),
        isFalse,
      );
    });

    test('separates super admin from regular admin except scoped override', () {
      expect(canAccessRouteForRole('super_admin', '/super-admin'), isTrue);
      expect(canAccessRouteForRole('super_admin', '/photo-ops'), isTrue);
      expect(canAccessRouteForRole('super_admin', '/admin'), isFalse);
      expect(canAccessRouteForRole('super_admin', '/admin/store-1'), isTrue);
      expect(canAccessRouteForRole('store_admin', '/super-admin'), isFalse);
    });

    test('keeps standalone QSC routes permission-gated', () {
      expect(canAccessRouteForRole('waiter', '/qc-check'), isFalse);
      expect(
        canAccessRouteForRole(
          'waiter',
          '/qc-check',
          extraPermissions: const ['qc_check'],
        ),
        isTrue,
      );
      expect(canAccessRouteForRole('waiter', '/qc-review'), isFalse);
      expect(
        canAccessRouteForRole(
          'waiter',
          '/qc-review',
          extraPermissions: const ['qc_visit_review'],
        ),
        isTrue,
      );
    });
  });
}
