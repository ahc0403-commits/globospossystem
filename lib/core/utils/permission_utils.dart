class PermissionUtils {
  static bool hasPermission(
    String? role,
    List<String> extraPermissions,
    String permission,
  ) {
    if (role == 'admin' || role == 'super_admin') return true;
    return extraPermissions.contains(permission);
  }

  static bool canDoQcCheck(String? role, List<String> extraPermissions) =>
      hasPermission(role, extraPermissions, 'qc_check');

  static bool canDoInventoryCount(
    String? role,
    List<String> extraPermissions,
  ) => hasPermission(role, extraPermissions, 'inventory_count');
}
