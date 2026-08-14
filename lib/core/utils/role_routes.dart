import 'permission_utils.dart';

/// Every role the POS client can route. auth_provider refuses to keep a
/// session whose role is outside this set, so `homeRouteForRole`'s '/login'
/// fallback can no longer trap an authenticated user in a redirect loop
/// (STAFF_ACCOUNT_LOGIN_GATE_CONTRACT_2026_07_03 P0-3).
const Set<String> kKnownPosRoles = {
  'super_admin',
  'brand_admin',
  'store_admin',
  'admin',
  'waiter',
  'kitchen',
  'cashier',
  'print_station',
  'customer_display',
  'emergency_station',
  'photo_objet_master',
  'photo_objet_store_operator',
};

/// Cross-store roles that may log in without an accessible-store scope
/// (contract AC6). Every other role is refused when its store list is empty.
const Set<String> kStoreScopeExemptRoles = {
  'super_admin',
  'photo_objet_master',
};

String homeRouteForRole(String? role) {
  return switch (role) {
    'super_admin' => '/super-admin',
    'photo_objet_master' || 'photo_objet_store_operator' => '/photo-ops',
    'brand_admin' || 'store_admin' || 'admin' => '/admin',
    'waiter' => '/waiter',
    'kitchen' => '/kitchen',
    'cashier' => '/cashier',
    'print_station' => '/print-station',
    'customer_display' => '/customer-display',
    'emergency_station' => '/emergency',
    _ => '/login',
  };
}

bool canAccessRouteForRole(
  String? role,
  String location, {
  List<String> extraPermissions = const <String>[],
}) {
  final path = Uri.parse(location).path;

  if (role == null) return path == '/login';
  if (path == '/change-password') return true;
  if (path == '/login' || path == '/onboarding' || path == '/privacy-consent') {
    return true;
  }
  if (path == '/attendance-kiosk') {
    return switch (role) {
      'super_admin' ||
      'brand_admin' ||
      'store_admin' ||
      'admin' ||
      'waiter' ||
      'kitchen' ||
      'cashier' => true,
      'photo_objet_master' || 'photo_objet_store_operator' => true,
      _ => false,
    };
  }
  if (path == '/print-station') {
    return switch (role) {
      'super_admin' ||
      'brand_admin' ||
      'store_admin' ||
      'admin' ||
      'kitchen' ||
      'cashier' ||
      'print_station' => true,
      _ => false,
    };
  }
  if (path.startsWith('/store-setup/')) {
    return PermissionUtils.isAdminLike(role);
  }
  if (path == '/qc-check') {
    return PermissionUtils.canDoQcCheck(role, extraPermissions);
  }
  if (path == '/qc-review') {
    return PermissionUtils.canDoQcVisitReview(role, extraPermissions);
  }
  if (path == '/receipts/today') {
    return switch (role) {
      'super_admin' ||
      'brand_admin' ||
      'store_admin' ||
      'admin' ||
      'cashier' => true,
      _ => false,
    };
  }

  return switch (role) {
    'super_admin' =>
      path == '/super-admin' ||
          path == '/restaurant-sales-export' ||
          path == '/red-invoice-export' ||
          path == '/photo-ops' ||
          path.startsWith('/store-setup/') ||
          path.startsWith('/admin/') ||
          path == '/receipts/today' ||
          path.startsWith('/payments/'),
    'brand_admin' || 'store_admin' || 'admin' =>
      path == '/admin' ||
          path == '/receipts/today' ||
          path.startsWith('/store-setup/') ||
          path.startsWith('/payments/'),
    'photo_objet_master' =>
      path == '/photo-ops' ||
          path == '/admin' ||
          path.startsWith('/store-setup/'),
    'photo_objet_store_operator' => path == '/photo-ops',
    'waiter' => path == '/waiter',
    'kitchen' => path == '/kitchen',
    'cashier' =>
      path == '/cashier' ||
          path == '/receipts/today' ||
          path == '/print-station' ||
          path.startsWith('/payments/'),
    'print_station' => path == '/print-station',
    'customer_display' => path == '/customer-display',
    'emergency_station' => path == '/emergency',
    _ => false,
  };
}
