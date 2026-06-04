import 'permission_utils.dart';

String homeRouteForRole(String? role) {
  return switch (role) {
    'super_admin' => '/super-admin',
    'photo_objet_master' || 'photo_objet_store_admin' => '/photo-ops',
    'brand_admin' || 'store_admin' || 'admin' => '/admin',
    'waiter' => '/waiter',
    'kitchen' => '/kitchen',
    'cashier' => '/cashier',
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
  if (path == '/login' || path == '/onboarding') return true;
  if (path == '/attendance-kiosk') return false;
  if (path == '/qc-check') {
    return PermissionUtils.canDoQcCheck(role, extraPermissions);
  }
  if (path == '/qc-review') {
    return PermissionUtils.canDoQcVisitReview(role, extraPermissions);
  }

  return switch (role) {
    'super_admin' =>
      path == '/super-admin' ||
          path == '/photo-ops' ||
          path.startsWith('/admin/') ||
          path.startsWith('/payments/'),
    'brand_admin' ||
    'store_admin' ||
    'admin' => path == '/admin' || path.startsWith('/payments/'),
    'photo_objet_master' || 'photo_objet_store_admin' => path == '/photo-ops',
    'waiter' => path == '/waiter',
    'kitchen' => path == '/kitchen',
    'cashier' => path == '/cashier' || path.startsWith('/payments/'),
    _ => false,
  };
}
