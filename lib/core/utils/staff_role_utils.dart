import 'package:flutter/material.dart';

import '../i18n/locale_extensions.dart';
import '../ui/pos_design_tokens.dart';

String roleMenuLabel(String role) {
  return switch (role.toLowerCase()) {
    'waiter' => 'Waiter',
    'kitchen' => 'Kitchen',
    'cashier' => 'Cashier',
    'admin' => 'Admin',
    'store_admin' => 'Store Admin',
    'brand_admin' => 'Brand Admin',
    'photo_objet_master' => 'Photo Objet Master',
    'photo_objet_store_operator' => 'Photo Objet Store Operator',
    'super_admin' => 'Super Admin',
    _ => roleDisplayName(role),
  };
}

String roleDisplayName(String role) {
  return switch (role.toLowerCase()) {
    'waiter' => 'Hall Staff',
    'kitchen' => 'Kitchen',
    'cashier' => 'Cashier',
    'admin' => 'Admin',
    'store_admin' => 'Store Admin',
    'brand_admin' => 'Brand Admin',
    'photo_objet_master' => 'Photo Objet Master',
    'photo_objet_store_operator' => 'Photo Objet Store Operator',
    'super_admin' => 'Super Admin',
    _ => role,
  };
}

Color roleAccentColor(String role) {
  return switch (role.toLowerCase()) {
    'waiter' => PosColors.info,
    'kitchen' => PosColors.warning,
    'cashier' => PosColors.success,
    'admin' => PosColors.accent,
    'store_admin' => const Color(0xFF7C5CFA),
    'brand_admin' => const Color(0xFFFF8A3D),
    'photo_objet_master' => const Color(0xFF00BFA5),
    'photo_objet_store_operator' => const Color(0xFF4DD0E1),
    _ => PosColors.border,
  };
}

String localizedRoleMenuLabel(BuildContext context, String role) {
  return switch (role.toLowerCase()) {
    'waiter' => context.l10n.roleWaiterMenu,
    'kitchen' => context.l10n.roleKitchenMenu,
    'cashier' => context.l10n.roleCashierMenu,
    'admin' => context.l10n.roleAdminMenu,
    'store_admin' => context.l10n.roleStoreAdminMenu,
    'brand_admin' => context.l10n.roleBrandAdminMenu,
    'photo_objet_master' => context.l10n.rolePhotoObjetMasterMenu,
    'photo_objet_store_operator' =>
      context.l10n.rolePhotoObjetStoreOperatorMenu,
    'super_admin' => context.l10n.roleSuperAdminMenu,
    _ => localizedRoleDisplayName(context, role),
  };
}

String localizedRoleDisplayName(BuildContext context, String role) {
  return switch (role.toLowerCase()) {
    'waiter' => context.l10n.roleWaiterDisplay,
    'kitchen' => context.l10n.roleKitchenDisplay,
    'cashier' => context.l10n.roleCashierDisplay,
    'admin' => context.l10n.roleAdminDisplay,
    'store_admin' => context.l10n.roleStoreAdminDisplay,
    'brand_admin' => context.l10n.roleBrandAdminDisplay,
    'photo_objet_master' => context.l10n.rolePhotoObjetMasterDisplay,
    'photo_objet_store_operator' =>
      context.l10n.rolePhotoObjetStoreOperatorDisplay,
    'super_admin' => context.l10n.roleSuperAdminDisplay,
    _ => role,
  };
}

bool canManageExtraPermissions(String role) {
  switch (role.toLowerCase()) {
    case 'admin':
    case 'store_admin':
    case 'brand_admin':
    case 'photo_objet_master':
    case 'photo_objet_store_operator':
    case 'super_admin':
      return false;
    default:
      return true;
  }
}

List<String> assignableRolesForViewer(String? viewerRole) {
  const baseRoles = ['waiter', 'kitchen', 'cashier'];

  if (viewerRole == 'super_admin') {
    return [...baseRoles, 'store_admin', 'brand_admin', 'photo_objet_master'];
  }

  if (viewerRole == 'brand_admin') {
    return [...baseRoles, 'store_admin'];
  }

  if (viewerRole == 'admin' || viewerRole == 'store_admin') {
    return [...baseRoles];
  }

  return [...baseRoles];
}

bool canMutateStaffAccount({
  required String? viewerRole,
  required String targetRole,
}) {
  final actor = viewerRole?.toLowerCase();
  final target = targetRole.toLowerCase();

  if (actor == 'super_admin') return true;

  if (actor == 'brand_admin') {
    return !const {
      'brand_admin',
      'super_admin',
      'photo_objet_master',
      'photo_objet_store_operator',
    }.contains(target);
  }

  if (actor == 'admin' || actor == 'store_admin') {
    return !const {
      'admin',
      'store_admin',
      'brand_admin',
      'super_admin',
      'photo_objet_master',
      'photo_objet_store_operator',
    }.contains(target);
  }

  return false;
}
