import { resolveMeInvoiceEntityAuth, type SellerConfig } from "./meinvoice.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${String(expected)}`);
  }
}

function assertThrows(fn: () => unknown, expectedMessage: string): Error {
  try {
    fn();
  } catch (error) {
    assert(error instanceof Error, "resolver must throw Error");
    assertEquals(error.message, expectedMessage, "unexpected error code");
    return error;
  }
  throw new Error(`expected resolver failure: ${expectedMessage}`);
}

function seller(
  taxEntityId: string,
  taxCode: string,
  clientId: string,
  invoiceSeries: string,
): SellerConfig {
  return {
    taxEntityId,
    taxCode,
    sellerName: taxEntityId,
    authBaseUrl: "https://misa.invalid/invoice",
    apiBaseUrl: "https://misa.invalid/invoice",
    clientId,
    invoiceSeries,
    integrationStatus: "active",
  };
}

function reader(values: Record<string, string>) {
  return (name: string) => values[name];
}

Deno.test("same brand uses each store legal entity credentials", () => {
  const sharedBrandId = "brand-photo";
  const stores = [
    {
      brandId: sharedBrandId,
      seller: seller("entity-a", "010-001", "client-a", "1C26MAA"),
    },
    {
      brandId: sharedBrandId,
      seller: seller("entity-b", "020.002", "client-b", "1C26MBB"),
    },
  ];
  assertEquals(stores[0].brandId, stores[1].brandId, "fixture brand mismatch");

  const env = reader({
    MISA_MEINVOICE_USERNAME_010_001: "user-a",
    MISA_MEINVOICE_PASSWORD_010_001: "password-a",
    MISA_MEINVOICE_CLIENT_SECRET_010_001: "secret-a",
    MISA_MEINVOICE_USERNAME_020_002: "user-b",
    MISA_MEINVOICE_PASSWORD_020_002: "password-b",
    MISA_MEINVOICE_CLIENT_SECRET_020_002: "secret-b",
  });
  const authA = resolveMeInvoiceEntityAuth(stores[0].seller, env);
  const authB = resolveMeInvoiceEntityAuth(stores[1].seller, env);

  assertEquals(authA.clientId, "client-a", "entity A ClientID mismatch");
  assertEquals(authB.clientId, "client-b", "entity B ClientID mismatch");
  assertEquals(authA.invoiceSeries, "1C26MAA", "entity A series mismatch");
  assertEquals(authB.invoiceSeries, "1C26MBB", "entity B series mismatch");
  assertEquals(authA.username, "user-a", "entity A username mismatch");
  assertEquals(authB.username, "user-b", "entity B username mismatch");
  assertEquals(authA.password, "password-a", "entity A password mismatch");
  assertEquals(authB.password, "password-b", "entity B password mismatch");
  assertEquals(authA.clientSecret, "secret-a", "entity A secret mismatch");
  assertEquals(authB.clientSecret, "secret-b", "entity B secret mismatch");
  assert(
    authA.clientSecret !== authB.clientSecret,
    "secrets must not cross entities",
  );
});

Deno.test("missing entity-specific secrets fail closed", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  const sharedOnly = reader({
    MISA_MEINVOICE_USERNAME: "shared-user",
    MISA_MEINVOICE_PASSWORD: "shared-password",
    MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
  });
  assertThrows(
    () => resolveMeInvoiceEntityAuth(entity, sharedOnly),
    "MEINVOICE_CREDENTIAL_NOT_CONFIGURED",
  );
});

Deno.test("shared secrets require explicit transition flag", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  const auth = resolveMeInvoiceEntityAuth(
    entity,
    reader({
      MISA_MEINVOICE_ALLOW_SHARED_SECRETS: "true",
      MISA_MEINVOICE_USERNAME: "shared-user",
      MISA_MEINVOICE_PASSWORD: "shared-password",
      MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
    }),
  );
  assertEquals(auth.username, "shared-user", "shared username mismatch");
  assertEquals(auth.password, "shared-password", "shared password mismatch");
  assertEquals(auth.clientSecret, "shared-secret", "shared secret mismatch");
});

Deno.test("partial entity credentials never mix with enabled shared values", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  const error = assertThrows(
    () =>
      resolveMeInvoiceEntityAuth(
        entity,
        reader({
          MISA_MEINVOICE_ALLOW_SHARED_SECRETS: "true",
          MISA_MEINVOICE_USERNAME_010001: "entity-user",
          MISA_MEINVOICE_PASSWORD: "shared-password",
          MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
        }),
      ),
    "MEINVOICE_ENTITY_CREDENTIAL_INCOMPLETE",
  );
  assert(!error.message.includes("entity-user"), "error leaked entity value");
  assert(!error.message.includes("shared"), "error leaked shared value");
});

Deno.test("complete entity credentials take precedence as one set", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  const auth = resolveMeInvoiceEntityAuth(
    entity,
    reader({
      MISA_MEINVOICE_ALLOW_SHARED_SECRETS: "true",
      MISA_MEINVOICE_USERNAME_010001: "entity-user",
      MISA_MEINVOICE_PASSWORD_010001: "entity-password",
      MISA_MEINVOICE_CLIENT_SECRET_010001: "entity-secret",
      MISA_MEINVOICE_USERNAME: "shared-user",
      MISA_MEINVOICE_PASSWORD: "shared-password",
      MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
    }),
  );
  assertEquals(auth.username, "entity-user", "entity username not selected");
  assertEquals(
    auth.password,
    "entity-password",
    "entity password not selected",
  );
  assertEquals(
    auth.clientSecret,
    "entity-secret",
    "entity secret not selected",
  );
});

Deno.test("partial shared credentials fail closed", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  assertThrows(
    () =>
      resolveMeInvoiceEntityAuth(
        entity,
        reader({
          MISA_MEINVOICE_ALLOW_SHARED_SECRETS: "true",
          MISA_MEINVOICE_USERNAME: "shared-user",
          MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
        }),
      ),
    "MEINVOICE_CREDENTIAL_NOT_CONFIGURED",
  );
});

Deno.test("whitespace entity values count as an incomplete set", () => {
  const entity = seller("entity-a", "010001", "client-a", "1C26MAA");
  assertThrows(
    () =>
      resolveMeInvoiceEntityAuth(
        entity,
        reader({
          MISA_MEINVOICE_ALLOW_SHARED_SECRETS: "true",
          MISA_MEINVOICE_USERNAME_010001: "entity-user",
          MISA_MEINVOICE_PASSWORD_010001: "   ",
          MISA_MEINVOICE_CLIENT_SECRET_010001: "entity-secret",
          MISA_MEINVOICE_USERNAME: "shared-user",
          MISA_MEINVOICE_PASSWORD: "shared-password",
          MISA_MEINVOICE_CLIENT_SECRET: "shared-secret",
        }),
      ),
    "MEINVOICE_ENTITY_CREDENTIAL_INCOMPLETE",
  );
});
