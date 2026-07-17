export const POS_PROJECT_REF = "ynriuoomotxuwhuxxmhj";
export const POS_PROJECT_URL = `https://${POS_PROJECT_REF}.supabase.co`;
export const POS_MASTER_EMAIL = "andre@globos.world";
export const POS_MASTER_FIXED_CODE = "andre";
export const POS_MASTER_ROLE = "super_admin";
export const POS_MASTER_ACCOUNT_TYPE = "master";
export const POS_MASTER_CONFIRMATION = "BOOTSTRAP_POS_MASTER_ANDRE";

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface BootstrapEnvironment {
  POS_SUPABASE_URL?: string;
  POS_SUPABASE_SERVICE_ROLE_KEY?: string;
  POS_MASTER_PASSWORD?: string;
  POS_MASTER_ANCHOR_STORE_ID?: string;
  CONFIRM_POS_MASTER_BOOTSTRAP?: string;
}

export interface BootstrapConfig {
  supabaseUrl: string;
  serviceRoleKey: string;
  password: string;
  anchorStoreId: string;
}

export interface ExistingMasterState {
  authId: string;
  authEmail: string;
  emailConfirmed: boolean;
  authRole: unknown;
  authAccountType: unknown;
  authFixedCode: unknown;
  profileAuthId: string;
  profileRole: string;
  profileAccountType: string;
  profileFixedCode: string;
  profileRestaurantId: string;
  profilePrimaryStoreId: string | null;
  profileActive: boolean;
  hasActivePrimaryAccess: boolean;
}

export function parseBootstrapEnvironment(
  env: BootstrapEnvironment,
): BootstrapConfig {
  const url = (env.POS_SUPABASE_URL ?? "").replace(/\/+$/, "");
  if (url !== POS_PROJECT_URL) {
    throw new Error(`POS_PROJECT_GUARD_FAILED:${POS_PROJECT_REF}`);
  }
  if (env.CONFIRM_POS_MASTER_BOOTSTRAP !== POS_MASTER_CONFIRMATION) {
    throw new Error("POS_MASTER_EXPLICIT_CONFIRMATION_REQUIRED");
  }
  const serviceRoleKey = env.POS_SUPABASE_SERVICE_ROLE_KEY ?? "";
  if (serviceRoleKey.length < 32) {
    throw new Error("POS_SERVICE_ROLE_KEY_REQUIRED");
  }
  const password = env.POS_MASTER_PASSWORD ?? "";
  if (password.length < 12) {
    throw new Error("POS_MASTER_PASSWORD_MINIMUM_12_CHARACTERS");
  }
  const anchorStoreId = env.POS_MASTER_ANCHOR_STORE_ID ?? "";
  if (!uuidPattern.test(anchorStoreId)) {
    throw new Error("POS_MASTER_ANCHOR_STORE_ID_UUID_REQUIRED");
  }
  return { supabaseUrl: url, serviceRoleKey, password, anchorStoreId };
}

export function verifyExistingMasterState(state: ExistingMasterState): void {
  const failures: string[] = [];
  if (state.authEmail.toLowerCase() !== POS_MASTER_EMAIL) {
    failures.push("auth_email");
  }
  if (!state.emailConfirmed) failures.push("email_confirmation");
  if (state.authId !== state.profileAuthId) failures.push("auth_profile_link");
  if (state.profileRole !== POS_MASTER_ROLE) failures.push("profile_role");
  if (state.profileAccountType !== POS_MASTER_ACCOUNT_TYPE) {
    failures.push("profile_account_type");
  }
  if (state.profileFixedCode !== POS_MASTER_FIXED_CODE) {
    failures.push("profile_fixed_code");
  }
  if (!state.profileActive) failures.push("profile_active");
  if (state.profilePrimaryStoreId !== state.profileRestaurantId) {
    failures.push("profile_primary_store");
  }
  if (!state.hasActivePrimaryAccess) failures.push("primary_store_access");
  if (state.authRole !== POS_MASTER_ROLE) failures.push("claim_role");
  if (state.authAccountType !== POS_MASTER_ACCOUNT_TYPE) {
    failures.push("claim_account_type");
  }
  if (state.authFixedCode !== POS_MASTER_FIXED_CODE) {
    failures.push("claim_fixed_account_code");
  }
  if (failures.length > 0) {
    throw new Error(`POS_MASTER_STATE_MISMATCH:${failures.join(",")}`);
  }
}
