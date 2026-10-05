export function canProvisionFixedAccount(
  callerRole: string,
  requirement: { scope: string; role: string; account_type: string },
): boolean {
  if (
    requirement.scope === "legal_entity" ||
    requirement.role === "inventory_accounting" ||
    requirement.account_type === "inventory_accounting"
  ) return callerRole === "super_admin";
  if (callerRole === "super_admin") return true;
  if (["brand_admin", "photo_objet_master"].includes(callerRole)) {
    return !["brand_admin", "photo_objet_master"].includes(requirement.role);
  }
  if (["admin", "store_admin"].includes(callerRole)) {
    return requirement.scope === "store" &&
      !["brand_manager", "store_manager", "inventory_accounting"].includes(
        requirement.account_type,
      ) &&
      !["brand_admin", "photo_objet_master", "store_admin"].includes(
        requirement.role,
      );
  }
  return false;
}
