class PermissionUtils {
  static bool isAdminLike(String? role) =>
      role == 'admin' ||
      role == 'store_admin' ||
      role == 'brand_admin' ||
      role == 'super_admin';

  static bool isPhotoObjetRole(String? role) =>
      role == 'photo_objet_master' || role == 'photo_objet_store_admin';

  static bool canAccessPhotoOps(String? role) =>
      role == 'super_admin' || isPhotoObjetRole(role);

  static bool canAccessDeliverySettlement(String? role) => isAdminLike(role);

  static bool hasPermission(
    String? role,
    List<String> extraPermissions,
    String permission,
  ) {
    if (isAdminLike(role)) return true;
    return extraPermissions.contains(permission);
  }

  static bool canDoQcCheck(String? role, List<String> extraPermissions) =>
      hasPermission(role, extraPermissions, 'qc_check');

  static bool canDoInventoryCount(
    String? role,
    List<String> extraPermissions,
  ) => hasPermission(role, extraPermissions, 'inventory_count');
}
