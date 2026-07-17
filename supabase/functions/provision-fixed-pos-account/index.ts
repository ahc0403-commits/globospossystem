import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
  type User,
} from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGINS[0] ?? "",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const ACCOUNT_DOMAIN = "globos.world";
const ACCOUNT_CODE = /^[a-z][a-z0-9_]{1,31}$/;

type Requirement = {
  id: string;
  store_id: string;
  account_code: string;
  account_type: string;
  role: string;
  display_name: string;
  scope: "brand" | "store";
  provisioned_user_id: string | null;
  is_active: boolean;
};

type CallerProfile = {
  id: string;
  role: string;
};

function response(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function canProvision(callerRole: string, requirement: Requirement): boolean {
  if (callerRole === "super_admin") return true;
  if (["brand_admin", "photo_objet_master"].includes(callerRole)) {
    return !["brand_admin", "photo_objet_master"].includes(requirement.role);
  }
  if (["admin", "store_admin"].includes(callerRole)) {
    return !["brand_manager", "store_manager"].includes(
      requirement.account_type,
    ) &&
      !["brand_admin", "photo_objet_master", "store_admin"].includes(
        requirement.role,
      );
  }
  return false;
}

async function findAuthUserByEmail(
  client: SupabaseClient,
  email: string,
): Promise<User | null> {
  for (let page = 1; page <= 20; page += 1) {
    const { data, error } = await client.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) throw error;
    const found = data.users.find((user) =>
      user.email?.toLowerCase() === email
    );
    if (found) return found;
    if (data.users.length < 1000) return null;
  }
  throw new Error("AUTH_DIRECTORY_SCAN_LIMIT");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return response(405, { error: "METHOD_NOT_ALLOWED" });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return response(401, { error: "UNAUTHORIZED" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return response(500, { error: "SERVER_CONFIGURATION_MISSING" });
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const serviceClient = createClient(supabaseUrl, serviceRoleKey);

  try {
    const { data: authData, error: authError } = await callerClient.auth
      .getUser();
    if (authError || !authData.user) {
      return response(401, { error: "UNAUTHORIZED" });
    }

    const { data: caller, error: callerError } = await callerClient
      .from("users")
      .select("id, role")
      .eq("auth_id", authData.user.id)
      .eq("is_active", true)
      .single<CallerProfile>();
    if (callerError || !caller) {
      return response(403, { error: "CALLER_PROFILE_FORBIDDEN" });
    }

    const body = await req.json() as Record<string, unknown>;
    const requirementId = typeof body.requirement_id === "string"
      ? body.requirement_id
      : "";
    const password = typeof body.password === "string" ? body.password : "";
    const rotatePassword = body.rotate_password === true;
    if (!requirementId) {
      return response(400, { error: "REQUIREMENT_ID_REQUIRED" });
    }

    const { data: requirement, error: requirementError } = await callerClient
      .from("store_fixed_account_requirements")
      .select(
        "id, store_id, account_code, account_type, role, display_name, scope, provisioned_user_id, is_active",
      )
      .eq("id", requirementId)
      .single<Requirement>();
    if (requirementError || !requirement || !requirement.is_active) {
      return response(404, { error: "ACCOUNT_REQUIREMENT_NOT_FOUND" });
    }
    if (!canProvision(caller.role, requirement)) {
      return response(403, { error: "ACCOUNT_PROVISION_FORBIDDEN" });
    }
    if (!ACCOUNT_CODE.test(requirement.account_code)) {
      return response(409, { error: "ACCOUNT_CODE_CONTRACT_INVALID" });
    }

    const email = `${requirement.account_code}@${ACCOUNT_DOMAIN}`;
    const { data: store, error: storeError } = await serviceClient
      .from("restaurants")
      .select("id, brand_id, is_active")
      .eq("id", requirement.store_id)
      .single();
    if (storeError || !store || store.is_active === false) {
      return response(409, { error: "ACCOUNT_STORE_UNAVAILABLE" });
    }

    const { data: fixedProfile, error: fixedProfileError } = await serviceClient
      .from("users")
      .select("id, auth_id, role, account_type, is_active")
      .eq("fixed_account_code", requirement.account_code)
      .maybeSingle();
    if (fixedProfileError) throw fixedProfileError;

    let authUser: User | null = fixedProfile
      ? (await serviceClient.auth.admin.getUserById(fixedProfile.auth_id)).data
        .user
      : await findAuthUserByEmail(serviceClient, email);
    let profile = fixedProfile;
    let createdAuthUser = false;
    let createdProfile = false;

    if (
      profile && (
        profile.role !== requirement.role ||
        profile.account_type !== requirement.account_type
      )
    ) {
      return response(409, { error: "FIXED_ACCOUNT_IDENTITY_CONFLICT" });
    }
    if (profile && !authUser) {
      return response(409, { error: "FIXED_ACCOUNT_AUTH_MISSING" });
    }
    if (authUser && authUser.email?.toLowerCase() !== email) {
      return response(409, { error: "FIXED_ACCOUNT_EMAIL_CONFLICT" });
    }
    if (!authUser && !password) {
      return response(400, { error: "INITIAL_PASSWORD_REQUIRED" });
    }
    if ((password || rotatePassword) && password.length < 12) {
      return response(400, { error: "PASSWORD_MINIMUM_12" });
    }

    if (!authUser) {
      const { data, error } = await serviceClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name: requirement.display_name },
      });
      if (error || !data.user) throw error ?? new Error("AUTH_CREATE_FAILED");
      authUser = data.user;
      createdAuthUser = true;
    } else if (rotatePassword) {
      const { error } = await serviceClient.auth.admin.updateUserById(
        authUser.id,
        {
          password,
        },
      );
      if (error) throw error;
    }

    if (!profile) {
      const { data, error } = await serviceClient.from("users").insert({
        auth_id: authUser.id,
        restaurant_id: requirement.store_id,
        primary_store_id: requirement.store_id,
        brand_id: store.brand_id,
        role: requirement.role,
        full_name: requirement.display_name,
        is_active: true,
        account_type: requirement.account_type,
        fixed_account_code: requirement.account_code,
      }).select("id, auth_id, role, account_type, is_active").single();
      if (error || !data) {
        if (createdAuthUser) {
          await serviceClient.auth.admin.deleteUser(authUser.id);
        }
        throw error ?? new Error("PROFILE_CREATE_FAILED");
      }
      profile = data;
      createdProfile = true;
    } else if (!profile.is_active) {
      const { data, error } = await serviceClient.from("users")
        .update({ is_active: true })
        .eq("id", profile.id)
        .select("id, auth_id, role, account_type, is_active")
        .single();
      if (error || !data) throw error ?? new Error("PROFILE_REACTIVATE_FAILED");
      profile = data;
    }

    const rollbackNewIdentity = async () => {
      if (createdProfile && profile) {
        await serviceClient.from("user_brand_access").delete().eq(
          "user_id",
          profile.id,
        );
        await serviceClient.from("user_store_access").delete().eq(
          "user_id",
          profile.id,
        );
        await serviceClient.from("users").delete().eq("id", profile.id);
      }
      if (createdAuthUser && authUser) {
        await serviceClient.auth.admin.deleteUser(authUser.id);
      }
    };

    const { error: storeAccessError } = await serviceClient.from(
      "user_store_access",
    )
      .upsert({
        user_id: profile.id,
        store_id: requirement.store_id,
        is_primary: requirement.scope === "store",
        is_active: true,
        source_type: "direct",
        granted_by: caller.id,
      }, { onConflict: "user_id,store_id,source_type" });
    if (storeAccessError) {
      await rollbackNewIdentity();
      throw storeAccessError;
    }

    if (requirement.scope === "brand") {
      const { error: brandAccessError } = await serviceClient.from(
        "user_brand_access",
      )
        .upsert({
          user_id: profile.id,
          brand_id: store.brand_id,
          is_active: true,
          granted_by: caller.id,
        }, { onConflict: "user_id,brand_id" });
      if (brandAccessError) {
        await rollbackNewIdentity();
        throw brandAccessError;
      }
      const { error: syncError } = await serviceClient.rpc(
        "sync_user_store_access",
        {
          p_user_id: profile.id,
        },
      );
      if (syncError) {
        await rollbackNewIdentity();
        throw syncError;
      }
    }

    const { error: requirementUpdateError } = await serviceClient
      .from("store_fixed_account_requirements")
      .update({
        provisioned_user_id: profile.id,
        updated_at: new Date().toISOString(),
      })
      .eq("id", requirement.id);
    if (requirementUpdateError) {
      await rollbackNewIdentity();
      throw requirementUpdateError;
    }

    const { error: claimsError } = await serviceClient.rpc(
      "refresh_user_claims",
      {
        p_auth_user_id: authUser.id,
      },
    );
    if (claimsError) {
      await rollbackNewIdentity();
      throw claimsError;
    }

    return response(200, {
      account_code: requirement.account_code,
      email,
      account_type: requirement.account_type,
      role: requirement.role,
      store_id: requirement.store_id,
      created: createdAuthUser,
      password_rotated: rotatePassword,
    });
  } catch (error) {
    console.error("provision-fixed-pos-account error", error);
    return response(500, { error: "ACCOUNT_PROVISION_FAILED" });
  }
});
