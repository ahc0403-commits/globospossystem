import {
  createPasswordChangeHandler,
  type PasswordChangeDependencies,
} from "./index.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

function request(
  password = "SecureShift12!",
  extra: Record<string, unknown> = {},
) {
  return new Request("https://example.test/functions/v1/password-change", {
    method: "POST",
    headers: {
      Authorization: "Bearer verified-session",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ new_password: password, ...extra }),
  });
}

function dependencies(
  overrides: Partial<PasswordChangeDependencies> = {},
): PasswordChangeDependencies {
  return {
    authenticate: () => Promise.resolve("auth-user-1"),
    loadProfile: () =>
      Promise.resolve({
        id: "profile-1",
        isActive: true,
        mustChangePassword: true,
        generation: 7,
        generationSupported: true,
      }),
    updatePassword: () => Promise.resolve(),
    completeGeneration: () => Promise.resolve(true),
    confirmLegacyCompletion: () => Promise.resolve(true),
    ...overrides,
  };
}

Deno.test("rejects an unverified caller and a weak password", async () => {
  const unauthenticated = createPasswordChangeHandler(
    dependencies({ authenticate: () => Promise.resolve(null) }),
  );
  assertEquals(
    (await unauthenticated(request())).status,
    401,
    "unauthenticated status",
  );

  const handler = createPasswordChangeHandler(dependencies());
  assertEquals(
    (await handler(request("too-short"))).status,
    400,
    "weak password status",
  );
});

Deno.test("changes only the authenticated user and completes the next generation", async () => {
  let updatedAuthId = "";
  let completedAuthId = "";
  let completedGeneration = -1;
  const handler = createPasswordChangeHandler(dependencies({
    updatePassword: (authId) => {
      updatedAuthId = authId;
      return Promise.resolve();
    },
    completeGeneration: (authId, generation) => {
      completedAuthId = authId;
      completedGeneration = generation;
      return Promise.resolve(true);
    },
  }));

  const result = await handler(request("SecureShift12!", {
    user_id: "attempted-other-user",
  }));
  assertEquals(result.status, 200, "success status");
  assertEquals(updatedAuthId, "auth-user-1", "password target");
  assertEquals(completedAuthId, "auth-user-1", "completion target");
  assertEquals(completedGeneration, 8, "completion generation");
});

Deno.test("keeps the gate armed when a concurrent reset advances generation", async () => {
  const handler = createPasswordChangeHandler(dependencies({
    completeGeneration: () => Promise.resolve(false),
  }));
  assertEquals(
    (await handler(request())).status,
    409,
    "concurrent reset status",
  );
});

Deno.test("keeps the gate armed when Auth password update fails", async () => {
  let completionAttempted = false;
  const handler = createPasswordChangeHandler(dependencies({
    updatePassword: () => Promise.reject(new Error("auth unavailable")),
    completeGeneration: () => {
      completionAttempted = true;
      return Promise.resolve(true);
    },
  }));
  assertEquals(
    (await handler(request())).status,
    500,
    "Auth failure status",
  );
  assertEquals(completionAttempted, false, "completion attempt");
});

Deno.test("supports the predecessor trigger during the compatibility release", async () => {
  let legacyChecked = false;
  const handler = createPasswordChangeHandler(dependencies({
    loadProfile: () =>
      Promise.resolve({
        id: "profile-1",
        isActive: true,
        mustChangePassword: true,
        generation: 0,
        generationSupported: false,
      }),
    confirmLegacyCompletion: () => {
      legacyChecked = true;
      return Promise.resolve(true);
    },
  }));
  assertEquals((await handler(request())).status, 200, "legacy status");
  assertEquals(legacyChecked, true, "legacy completion check");
});
