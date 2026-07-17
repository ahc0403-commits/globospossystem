import {
  createClient,
  type SupabaseClient,
  type User,
} from "npm:@supabase/supabase-js@2";
import {
  parseBootstrapEnvironment,
  POS_MASTER_ACCOUNT_TYPE,
  POS_MASTER_EMAIL,
  POS_MASTER_FIXED_CODE,
  POS_MASTER_ROLE,
  POS_PROJECT_REF,
  verifyExistingMasterState,
} from "./bootstrap_pos_master_account_lib.ts";

type Profile = {
  id: string;
  auth_id: string;
  restaurant_id: string;
  primary_store_id: string | null;
  role: string;
  account_type: string;
  fixed_account_code: string;
  is_active: boolean;
};

function fail(message: string): never {
  throw new Error(message);
}

async function verifyLinkedProject(): Promise<void> {
  const ref = (await Deno.readTextFile("supabase/.temp/project-ref")).trim();
  if (ref !== POS_PROJECT_REF) {
    fail(`POS_LINKED_PROJECT_GUARD_FAILED:${POS_PROJECT_REF}`);
  }
}

async function findAuthUser(client: SupabaseClient): Promise<User | null> {
  for (let page = 1; page <= 100; page += 1) {
    const { data, error } = await client.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) fail(`POS_AUTH_LOOKUP_FAILED:${error.message}`);
    const matches = data.users.filter(
      (user) => user.email?.toLowerCase() === POS_MASTER_EMAIL,
    );
    if (matches.length > 1) fail("POS_MASTER_DUPLICATE_AUTH_IDENTITIES");
    if (matches.length === 1) return matches[0];
    if (data.users.length < 1000) return null;
  }
  fail("POS_AUTH_LOOKUP_PAGE_LIMIT_EXCEEDED");
}

async function findProfile(client: SupabaseClient): Promise<Profile | null> {
  const { data, error } = await client.from("users")
    .select(
      "id,auth_id,restaurant_id,primary_store_id,role,account_type,fixed_account_code,is_active",
    )
    .eq("fixed_account_code", POS_MASTER_FIXED_CODE);
  if (error) fail(`POS_PROFILE_LOOKUP_FAILED:${error.message}`);
  if (data.length > 1) fail("POS_MASTER_DUPLICATE_PROFILES");
  return (data[0] as Profile | undefined) ?? null;
}

async function verifyState(
  client: SupabaseClient,
  authUser: User,
  profile: Profile,
): Promise<void> {
  const { data: access, error: accessError } = await client
    .from("user_store_access")
    .select("id")
    .eq("user_id", profile.id)
    .eq("store_id", profile.primary_store_id)
    .eq("is_primary", true)
    .eq("is_active", true)
    .limit(1);
  if (accessError) fail(`POS_ACCESS_LOOKUP_FAILED:${accessError.message}`);
  verifyExistingMasterState({
    authId: authUser.id,
    authEmail: authUser.email ?? "",
    emailConfirmed: Boolean(authUser.email_confirmed_at),
    authRole: authUser.app_metadata?.role,
    authAccountType: authUser.app_metadata?.account_type,
    authFixedCode: authUser.app_metadata?.fixed_account_code,
    profileAuthId: profile.auth_id,
    profileRole: profile.role,
    profileAccountType: profile.account_type,
    profileFixedCode: profile.fixed_account_code,
    profileRestaurantId: profile.restaurant_id,
    profilePrimaryStoreId: profile.primary_store_id,
    profileActive: profile.is_active,
    hasActivePrimaryAccess: access.length === 1,
  });
}

async function bootstrap(): Promise<void> {
  await verifyLinkedProject();
  const config = parseBootstrapEnvironment(Deno.env.toObject());
  const client = createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const existingAuth = await findAuthUser(client);
  const existingProfile = await findProfile(client);
  if (existingAuth || existingProfile) {
    if (!existingAuth || !existingProfile) {
      fail("POS_MASTER_ORPHANED_EXISTING_IDENTITY");
    }
    await verifyState(client, existingAuth, existingProfile);
    console.log("POS master account already exists and is exactly consistent.");
    return;
  }

  const { data: store, error: storeError } = await client.from("restaurants")
    .select("id,is_active")
    .eq("id", config.anchorStoreId)
    .maybeSingle();
  if (storeError) fail(`POS_ANCHOR_STORE_LOOKUP_FAILED:${storeError.message}`);
  if (!store || store.is_active !== true) {
    fail("POS_MASTER_ANCHOR_STORE_NOT_ACTIVE");
  }

  let createdAuthId: string | null = null;
  try {
    const { data: created, error: createError } = await client.auth.admin
      .createUser({
        email: POS_MASTER_EMAIL,
        password: config.password,
        email_confirm: true,
        app_metadata: {
          role: POS_MASTER_ROLE,
          account_type: POS_MASTER_ACCOUNT_TYPE,
          fixed_account_code: POS_MASTER_FIXED_CODE,
        },
      });
    if (createError || !created.user) {
      fail(
        `POS_MASTER_AUTH_CREATE_FAILED:${
          createError?.message ?? "missing user"
        }`,
      );
    }
    createdAuthId = created.user.id;

    const { data: profile, error: profileError } = await client.from("users")
      .insert({
        auth_id: createdAuthId,
        restaurant_id: config.anchorStoreId,
        primary_store_id: config.anchorStoreId,
        role: POS_MASTER_ROLE,
        account_type: POS_MASTER_ACCOUNT_TYPE,
        fixed_account_code: POS_MASTER_FIXED_CODE,
        full_name: "Andre",
        is_active: true,
      })
      .select(
        "id,auth_id,restaurant_id,primary_store_id,role,account_type,fixed_account_code,is_active",
      )
      .single();
    if (profileError || !profile) {
      fail(
        `POS_MASTER_PROFILE_CREATE_FAILED:${
          profileError?.message ?? "missing profile"
        }`,
      );
    }
    const { error: accessError } = await client.from("user_store_access")
      .insert({
        user_id: profile.id,
        store_id: config.anchorStoreId,
        is_primary: true,
        is_active: true,
        source_type: "direct",
      });
    if (accessError) {
      fail(`POS_MASTER_ACCESS_CREATE_FAILED:${accessError.message}`);
    }
    const { error: claimsError } = await client.rpc("refresh_user_claims", {
      p_auth_user_id: createdAuthId,
    });
    if (claimsError) {
      fail(`POS_MASTER_CLAIMS_REFRESH_FAILED:${claimsError.message}`);
    }

    const { data: refreshed, error: refreshedError } = await client.auth.admin
      .getUserById(createdAuthId);
    if (refreshedError || !refreshed.user) {
      fail(
        `POS_MASTER_AUTH_VERIFY_FAILED:${
          refreshedError?.message ?? "missing user"
        }`,
      );
    }
    await verifyState(client, refreshed.user, profile as Profile);
    console.log("POS master account created and verified.");
  } catch (error) {
    if (createdAuthId) {
      // Deleting the Auth identity created in this run cascades only its newly
      // created POS profile/access. Pre-existing identities are never changed.
      const { error: rollbackError } = await client.auth.admin.deleteUser(
        createdAuthId,
      );
      if (rollbackError) {
        console.error("POS_MASTER_CURRENT_RUN_ROLLBACK_FAILED");
      }
    }
    throw error;
  }
}

if (import.meta.main) {
  bootstrap().catch((error) => {
    console.error(
      error instanceof Error ? error.message : "POS_MASTER_BOOTSTRAP_FAILED",
    );
    Deno.exit(1);
  });
}
