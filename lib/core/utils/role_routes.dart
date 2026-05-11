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

bool canAccessRouteForRole(String? role, String location) {
  if (role == null) return location == '/login';
  if (location == '/login' || location == '/onboarding') return true;
  if (location == '/qc-check') return true;
  if (location == '/qc-review') return true;
  if (location == '/attendance-kiosk') return true;

  return switch (role) {
    'super_admin' =>
      location == '/super-admin' ||
          location == '/photo-ops' ||
          location.startsWith('/admin/') ||
          location.startsWith('/payments/'),
    'brand_admin' ||
    'store_admin' ||
    'admin' => location == '/admin' || location.startsWith('/payments/'),
    'photo_objet_master' ||
    'photo_objet_store_admin' => location == '/photo-ops',
    'waiter' => location == '/waiter',
    'kitchen' => location == '/kitchen',
    'cashier' => location == '/cashier' || location.startsWith('/payments/'),
    _ => false,
  };
}
