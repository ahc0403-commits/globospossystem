import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);

type PasswordProfile = {
  id: string;
  isActive: boolean;
  mustChangePassword: boolean;
  generation: number;
  generationSupported: boolean;
};

export type PasswordChangeDependencies = {
  authenticate: () => Promise<string | null>;
  loadProfile: (authId: string) => Promise<PasswordProfile | null>;
  updatePassword: (authId: string, password: string) => Promise<void>;
  completeGeneration: (
    authId: string,
    expectedGeneration: number,
  ) => Promise<boolean>;
  confirmLegacyCompletion: (authId: string) => Promise<boolean>;
};

function corsHeaders(request: Request): Record<string, string> {
  const requestOrigin = request.headers.get("Origin") ?? "";
  const allowedOrigin = ALLOWED_ORIGINS.includes(requestOrigin)
    ? requestOrigin
    : ALLOWED_ORIGINS[0] ?? "";
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Cache-Control": "private, no-store",
    Vary: "Origin",
  };
}

function response(
  request: Request,
  status: number,
  payload: Record<string, unknown>,
) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders(request),
      "Content-Type": "application/json",
    },
  });
}

function isStrongPassword(value: string): boolean {
  return value.length >= 12 &&
    /[a-z]/.test(value) &&
    /[A-Z]/.test(value) &&
    /[0-9]/.test(value) &&
    /[^A-Za-z0-9]/.test(value);
}

export function createPasswordChangeHandler(
  dependencies: PasswordChangeDependencies,
) {
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders(request) });
    }
    if (request.method !== "POST") {
      return response(request, 405, { error: "METHOD_NOT_ALLOWED" });
    }
    if (!request.headers.get("Authorization")) {
      return response(request, 401, { error: "UNAUTHORIZED" });
    }

    let body: Record<string, unknown>;
    try {
      body = await request.json() as Record<string, unknown>;
    } catch (_) {
      return response(request, 400, { error: "INVALID_JSON" });
    }
    const newPassword = typeof body.new_password === "string"
      ? body.new_password
      : "";
    if (!isStrongPassword(newPassword)) {
      return response(request, 400, { error: "PASSWORD_POLICY_FAILED" });
    }

    try {
      const authId = await dependencies.authenticate();
      if (!authId) {
        return response(request, 401, { error: "UNAUTHORIZED" });
      }

      const profile = await dependencies.loadProfile(authId);
      if (!profile || !profile.isActive) {
        return response(request, 403, { error: "ACTIVE_PROFILE_REQUIRED" });
      }
      if (!profile.mustChangePassword) {
        return response(request, 409, {
          error: "PASSWORD_CHANGE_NOT_REQUIRED",
        });
      }

      await dependencies.updatePassword(authId, newPassword);

      const completed = profile.generationSupported
        ? await dependencies.completeGeneration(
          authId,
          profile.generation + 1,
        )
        : await dependencies.confirmLegacyCompletion(authId);
      if (!completed) {
        return response(request, 409, {
          error: "PASSWORD_CHANGE_GENERATION_CONFLICT",
        });
      }

      return response(request, 200, { password_changed: true });
    } catch (error) {
      console.error(
        "complete-initial-password-change failed",
        error instanceof Error ? error.message : "unknown error",
      );
      return response(request, 500, { error: "PASSWORD_CHANGE_FAILED" });
    }
  };
}

function buildProductionDependencies(
  request: Request,
): PasswordChangeDependencies {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authHeader = request.headers.get("Authorization") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    throw new Error("SERVER_CONFIGURATION_MISSING");
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return {
    authenticate: async () => {
      const { data, error } = await callerClient.auth.getUser();
      if (error || !data.user) return null;
      return data.user.id;
    },
    loadProfile: async (authId) => {
      const generationResult = await serviceClient
        .from("users")
        .select(
          "id,is_active,must_change_password,password_change_generation",
        )
        .eq("auth_id", authId)
        .maybeSingle();
      if (!generationResult.error && generationResult.data) {
        return {
          id: generationResult.data.id,
          isActive: generationResult.data.is_active === true,
          mustChangePassword:
            generationResult.data.must_change_password === true,
          generation: Number(
            generationResult.data.password_change_generation ?? 0,
          ),
          generationSupported: true,
        };
      }
      if (
        generationResult.error &&
        generationResult.error.code !== "42703" &&
        !generationResult.error.message.includes("password_change_generation")
      ) {
        throw generationResult.error;
      }

      // Compatibility for the first release step while the predecessor trigger
      // still owns completion. Remove this fallback only in a later release.
      const legacyResult = await serviceClient
        .from("users")
        .select("id,is_active,must_change_password")
        .eq("auth_id", authId)
        .maybeSingle();
      if (legacyResult.error) throw legacyResult.error;
      if (!legacyResult.data) return null;
      return {
        id: legacyResult.data.id,
        isActive: legacyResult.data.is_active === true,
        mustChangePassword: legacyResult.data.must_change_password === true,
        generation: 0,
        generationSupported: false,
      };
    },
    updatePassword: async (authId, password) => {
      const { error } = await serviceClient.auth.admin.updateUserById(authId, {
        password,
      });
      if (error) throw error;
    },
    completeGeneration: async (authId, expectedGeneration) => {
      const { data, error } = await serviceClient
        .from("users")
        .update({
          must_change_password: false,
          password_change_required_at: null,
          password_changed_at: new Date().toISOString(),
        })
        .eq("auth_id", authId)
        .eq("is_active", true)
        .eq("must_change_password", true)
        .eq("password_change_generation", expectedGeneration)
        .select("id")
        .maybeSingle();
      if (error) throw error;
      return data != null;
    },
    confirmLegacyCompletion: async (authId) => {
      const { data, error } = await serviceClient
        .from("users")
        .select("must_change_password")
        .eq("auth_id", authId)
        .maybeSingle();
      if (error) throw error;
      return data?.must_change_password === false;
    },
  };
}

if (import.meta.main) {
  serve((request) => {
    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders(request) });
    }
    try {
      return createPasswordChangeHandler(
        buildProductionDependencies(request),
      )(request);
    } catch (_) {
      return response(request, 500, {
        error: "SERVER_CONFIGURATION_MISSING",
      });
    }
  });
}
