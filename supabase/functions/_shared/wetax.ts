export const WETAX_BASE_URL = Deno.env.get("WETAX_BASE_URL") ??
  "https://apitest.wetax.com.vn";

const WETAX_ENCRYPTION_KEY = Deno.env.get("WETAX_ENCRYPTION_KEY");

export interface GetTokenOptions {
  functionName: string;
  accessReason: string;
  formatLoginError?: (status: number, body: unknown) => string;
}

export interface LogEventOptions {
  retryCount?: number | null;
  rawRequest?: unknown;
  rawResponse?: unknown;
}

async function encryptPassword(
  plain: string,
  encryptionKey: string,
): Promise<string> {
  const enc = new TextEncoder();
  const keyHash = await crypto.subtle.digest(
    "SHA-256",
    enc.encode(encryptionKey),
  );
  const keyBytes = new Uint8Array(keyHash);
  const keyHex = Array.from(keyBytes).map((b) =>
    b.toString(16).padStart(2, "0")
  ).join("");
  const iv = enc.encode(keyHex.substring(0, 16));

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "AES-CBC" },
    false,
    ["encrypt"],
  );

  const plainBytes = enc.encode(plain);
  const pad = 16 - (plainBytes.length % 16);
  const padded = new Uint8Array(plainBytes.length + pad);
  padded.set(plainBytes);
  padded.fill(pad, plainBytes.length);

  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-CBC", iv },
    cryptoKey,
    padded,
  );
  return btoa(String.fromCharCode(...new Uint8Array(encrypted)));
}

export function decodeByteaToString(v: unknown): string {
  if (!v) return "";
  if (v instanceof Uint8Array) return new TextDecoder().decode(v);
  const s = String(v);
  const hexMatch = s.match(/^[\\]?x([0-9a-fA-F]+)$/);
  if (hexMatch) {
    const bytes = new Uint8Array(hexMatch[1].length / 2);
    for (let i = 0; i < hexMatch[1].length; i += 2) {
      bytes[i / 2] = parseInt(hexMatch[1].substring(i, i + 2), 16);
    }
    return new TextDecoder().decode(bytes);
  }
  try {
    return atob(s);
  } catch {
    return s;
  }
}

function formatDefaultLoginError(status: number, body: unknown): string {
  return `WT00 failed ${status}: ${JSON.stringify(body)}`;
}

async function logCredentialAccess(
  supabase: any,
  credentialId: string,
  options: GetTokenOptions,
  success: boolean,
) {
  await supabase.from("partner_credential_access_log").insert({
    credential_id: credentialId,
    access_reason: options.accessReason,
    accessed_by_function: options.functionName,
    success,
  });
}

export async function getToken(
  supabase: any,
  options: GetTokenOptions,
): Promise<string> {
  const { data: cred, error } = await supabase
    .from("partner_credentials")
    .select(
      "id,user_id,password_value,password_format,current_token,token_expires_at",
    )
    .eq("data_source", "VNPT_EPAY")
    .single();

  if (error || !cred) {
    throw new Error("partner_credentials not found: " + error?.message);
  }

  const now = new Date();
  const expiresAt = cred.token_expires_at
    ? new Date(cred.token_expires_at)
    : null;
  const threshold = expiresAt
    ? new Date(expiresAt.getTime() - 15 * 60 * 1000)
    : now;

  if (cred.current_token && expiresAt && now < threshold) {
    return cred.current_token;
  }

  const passwordFormat = cred.password_format ?? "plaintext";
  let sendPassword = decodeByteaToString(cred.password_value);

  if (WETAX_ENCRYPTION_KEY && passwordFormat === "plaintext") {
    sendPassword = await encryptPassword(sendPassword, WETAX_ENCRYPTION_KEY);
    console.log("WT00: sending AES256-encrypted password");
  } else if (passwordFormat === "aes256_ciphertext") {
    console.log("WT00: sending stored AES256 ciphertext password");
  } else {
    console.log(
      "WT00: sending plaintext password (no WETAX_ENCRYPTION_KEY set)",
    );
  }

  let loginRes: Response;
  let loginBody: any;
  try {
    loginRes = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: cred.user_id, password: sendPassword }),
    });
    loginBody = await loginRes.json().catch(() => null);
  } catch (err) {
    await logCredentialAccess(supabase, cred.id, options, false);
    throw err;
  }

  if (!loginRes.ok || !loginBody?.data?.access_token) {
    await logCredentialAccess(supabase, cred.id, options, false);
    throw new Error(
      (options.formatLoginError ?? formatDefaultLoginError)(
        loginRes.status,
        loginBody,
      ),
    );
  }

  const token: string = loginBody.data.access_token;
  const expiresIn: number = loginBody.data.expires_in ?? 86400;
  await supabase.from("partner_credentials").update({
    current_token: token,
    token_expires_at: new Date(now.getTime() + expiresIn * 1000).toISOString(),
    last_verified_at: now.toISOString(),
    updated_at: now.toISOString(),
  }).eq("id", cred.id);

  await logCredentialAccess(supabase, cred.id, options, true);
  return token;
}

export async function getConfig(
  supabase: any,
  keys: string[],
): Promise<Record<string, string>> {
  const { data } = await supabase.from("system_config").select("key,value")
    .in("key", keys);
  const config: Record<string, string> = {};
  for (const row of data ?? []) config[row.key] = row.value;
  return config;
}

function hasLogEventOptionKeys(value: unknown): value is LogEventOptions {
  if (!value || typeof value !== "object") return false;
  return "retryCount" in value || "rawRequest" in value ||
    "rawResponse" in value;
}

export async function logEvent(
  supabase: any,
  jobId: string | null,
  eventType: string,
  description: string,
  optsOrRawResponse?: LogEventOptions | unknown,
) {
  const opts = hasLogEventOptionKeys(optsOrRawResponse)
    ? optsOrRawResponse
    : { rawResponse: optsOrRawResponse };

  await supabase.from("einvoice_events").insert({
    job_id: jobId,
    event_type: eventType,
    description,
    retry_count: opts.retryCount ?? null,
    raw_request: opts.rawRequest ? JSON.stringify(opts.rawRequest) : null,
    raw_response: opts.rawResponse ? JSON.stringify(opts.rawResponse) : null,
  });
}
