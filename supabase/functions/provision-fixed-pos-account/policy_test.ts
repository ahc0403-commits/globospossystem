import { canProvisionFixedAccount } from "./policy.ts";

function expect(value: boolean, expected: boolean) {
  if (value !== expected) throw new Error(`Expected ${expected}, got ${value}`);
}
Deno.test("only super admin can provision either store or legal entity verifiers", () => {
  for (const scope of ["store", "legal_entity"]) {
    const requirement = {
      scope,
      role: "inventory_accounting",
      account_type: "inventory_accounting",
    };
    for (
      const actor of [
        "brand_admin",
        "store_admin",
        "admin",
        "inventory_orderer",
        "inventory_accounting",
      ]
    ) {
      expect(canProvisionFixedAccount(actor, requirement), false);
    }
    expect(canProvisionFixedAccount("super_admin", requirement), true);
  }
});
Deno.test("store managers still provision orderers but cannot provision managers", () => {
  expect(
    canProvisionFixedAccount("store_admin", {
      scope: "store",
      role: "inventory_orderer",
      account_type: "inventory_orderer",
    }),
    true,
  );
  expect(
    canProvisionFixedAccount("store_admin", {
      scope: "store",
      role: "store_admin",
      account_type: "store_manager",
    }),
    false,
  );
});
Deno.test("brand provisioning and legal entity separation retain their authority", () => {
  expect(
    canProvisionFixedAccount("brand_admin", {
      scope: "store",
      role: "inventory_orderer",
      account_type: "inventory_orderer",
    }),
    true,
  );
  expect(
    canProvisionFixedAccount("brand_admin", {
      scope: "brand",
      role: "brand_admin",
      account_type: "brand_manager",
    }),
    false,
  );
  expect(
    canProvisionFixedAccount("brand_admin", {
      scope: "legal_entity",
      role: "inventory_orderer",
      account_type: "inventory_orderer",
    }),
    false,
  );
});
