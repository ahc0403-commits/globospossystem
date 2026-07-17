import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';

void main() {
  group('canAccessRouteForRole matrix', () {
    const roleRouteExpectations = <String, Map<String, bool>>{
      'super_admin': {
        '/super-admin': true,
        '/admin/some-store-id': true,
        '/payments/some-id': true,
        '/print-station': true,
        '/photo-ops': true,
        '/admin': false,
        '/waiter': false,
        '/kitchen': false,
        '/cashier': false,
      },
      'admin': {
        '/admin': true,
        '/payments/some-id': true,
        '/print-station': true,
        '/super-admin': false,
        '/waiter': false,
        '/kitchen': false,
        '/cashier': false,
        '/photo-ops': false,
        '/admin/some-store-id': false,
      },
      'brand_admin': {
        '/admin': true,
        '/payments/some-id': true,
        '/print-station': true,
        '/super-admin': false,
        '/waiter': false,
        '/kitchen': false,
        '/cashier': false,
      },
      'store_admin': {
        '/admin': true,
        '/payments/some-id': true,
        '/print-station': true,
        '/super-admin': false,
        '/waiter': false,
        '/kitchen': false,
      },
      'waiter': {
        '/waiter': true,
        '/print-station': false,
        '/cashier': false,
        '/kitchen': false,
        '/admin': false,
        '/super-admin': false,
        '/payments/some-id': false,
      },
      'kitchen': {
        '/kitchen': true,
        '/print-station': true,
        '/waiter': false,
        '/cashier': false,
        '/admin': false,
        '/super-admin': false,
        '/payments/some-id': false,
      },
      'cashier': {
        '/cashier': true,
        '/payments/some-id': true,
        '/print-station': true,
        '/waiter': false,
        '/kitchen': false,
        '/admin': false,
        '/super-admin': false,
      },
      'photo_objet_master': {
        '/photo-ops': true,
        '/print-station': false,
        '/admin': true,
        '/super-admin': false,
        '/waiter': false,
        '/cashier': false,
      },
      'photo_objet_store_operator': {
        '/photo-ops': true,
        '/attendance-kiosk': true,
        '/print-station': false,
        '/admin': false,
        '/super-admin': false,
        '/cashier': false,
      },
      'photo_objet_store_admin': {'/photo-ops': false, '/admin': false},
    };

    for (final roleEntry in roleRouteExpectations.entries) {
      final role = roleEntry.key;
      for (final routeEntry in roleEntry.value.entries) {
        final route = routeEntry.key;
        final expected = routeEntry.value;

        test('$role ${expected ? "can" : "cannot"} access $route', () {
          expect(
            canAccessRouteForRole(role, route),
            expected,
            reason: '$role should ${expected ? "" : "not "}access $route',
          );
        });
      }
    }

    test('all roles can access /login', () {
      for (final role in [
        'super_admin',
        'admin',
        'waiter',
        'kitchen',
        'cashier',
        'photo_objet_master',
        'photo_objet_store_operator',
      ]) {
        expect(canAccessRouteForRole(role, '/login'), isTrue);
      }
    });

    test('all roles can access /privacy-consent', () {
      for (final role in ['super_admin', 'admin', 'waiter']) {
        expect(canAccessRouteForRole(role, '/privacy-consent'), isTrue);
      }
    });

    test('store operating roles can access /attendance-kiosk', () {
      for (final role in [
        'super_admin',
        'brand_admin',
        'store_admin',
        'admin',
        'waiter',
        'kitchen',
        'cashier',
      ]) {
        expect(canAccessRouteForRole(role, '/attendance-kiosk'), isTrue);
      }

      expect(
        canAccessRouteForRole('photo_objet_store_admin', '/attendance-kiosk'),
        isFalse,
      );
    });

    test('null role can only access /login', () {
      expect(canAccessRouteForRole(null, '/login'), isTrue);
      expect(canAccessRouteForRole(null, '/admin'), isFalse);
      expect(canAccessRouteForRole(null, '/waiter'), isFalse);
    });
  });

  group('QC permission routes', () {
    test('admin-like roles can always access qc_check', () {
      expect(canAccessRouteForRole('admin', '/qc-check'), isTrue);
      expect(canAccessRouteForRole('super_admin', '/qc-check'), isTrue);
      expect(canAccessRouteForRole('store_admin', '/qc-check'), isTrue);
    });

    test('admin-like roles can always access qc_review', () {
      expect(canAccessRouteForRole('admin', '/qc-review'), isTrue);
      expect(canAccessRouteForRole('super_admin', '/qc-review'), isTrue);
    });

    test('waiter needs qc_check extra permission', () {
      expect(canAccessRouteForRole('waiter', '/qc-check'), isFalse);
      expect(
        canAccessRouteForRole(
          'waiter',
          '/qc-check',
          extraPermissions: ['qc_check'],
        ),
        isTrue,
      );
    });

    test('waiter needs qc_visit_review extra permission', () {
      expect(canAccessRouteForRole('waiter', '/qc-review'), isFalse);
      expect(
        canAccessRouteForRole(
          'waiter',
          '/qc-review',
          extraPermissions: ['qc_visit_review'],
        ),
        isTrue,
      );
    });

    test('cashier needs qc_check extra permission', () {
      expect(canAccessRouteForRole('cashier', '/qc-check'), isFalse);
      expect(
        canAccessRouteForRole(
          'cashier',
          '/qc-check',
          extraPermissions: ['qc_check'],
        ),
        isTrue,
      );
    });
  });

  group('homeRouteForRole', () {
    test('returns correct home for each role', () {
      expect(homeRouteForRole('super_admin'), '/super-admin');
      expect(homeRouteForRole('admin'), '/admin');
      expect(homeRouteForRole('brand_admin'), '/admin');
      expect(homeRouteForRole('store_admin'), '/admin');
      expect(homeRouteForRole('waiter'), '/waiter');
      expect(homeRouteForRole('kitchen'), '/kitchen');
      expect(homeRouteForRole('cashier'), '/cashier');
      expect(homeRouteForRole('photo_objet_master'), '/photo-ops');
      expect(homeRouteForRole('photo_objet_store_operator'), '/photo-ops');
      expect(homeRouteForRole('photo_objet_store_admin'), '/login');
      expect(homeRouteForRole(null), '/login');
      expect(homeRouteForRole('unknown_role'), '/login');
    });
  });
}
