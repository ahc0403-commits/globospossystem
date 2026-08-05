export type JsonRecord = Record<string, unknown>;

export interface SePayTransaction {
  id: number;
  gateway: string;
  accountNumber: string;
  subAccount: string | null;
  transferType: "in" | "out";
  transferAmount: number;
  paymentCode: string | null;
  referenceCode: string | null;
  transactionAt: string | null;
  rawPayload: JsonRecord;
}

function stringField(value: unknown): string | null {
  if (typeof value === "string" && value.trim().length > 0) {
    return value.trim();
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  return null;
}

function numberField(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizeSignature(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim().toLowerCase();
  return trimmed.startsWith("sha256=") ? trimmed.slice(7) : trimmed;
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) {
    diff |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return diff === 0;
}

async function hmacSha256Hex(
  secret: string,
  message: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

export async function verifySePaySignature(options: {
  secret: string;
  rawBody: string;
  signature: string | null;
  timestamp: string | null;
  nowMillis?: number;
  replayWindowSeconds?: number;
}): Promise<boolean> {
  const signature = normalizeSignature(options.signature);
  const timestampSeconds = Number(options.timestamp);
  if (!signature || !Number.isFinite(timestampSeconds)) return false;

  const nowMillis = options.nowMillis ?? Date.now();
  const replayWindowSeconds = options.replayWindowSeconds ?? 300;
  if (!Number.isFinite(replayWindowSeconds) || replayWindowSeconds <= 0) {
    return false;
  }
  if (
    Math.abs(nowMillis - timestampSeconds * 1000) / 1000 > replayWindowSeconds
  ) {
    return false;
  }

  const expected = await hmacSha256Hex(
    options.secret,
    `${options.timestamp}.${options.rawBody}`,
  );
  return constantTimeEqual(expected, signature);
}

function parseTransactionAt(value: string | null): string | null {
  if (!value) return null;
  const withTimezone = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value)
    ? `${value.replace(" ", "T")}+07:00`
    : value;
  const millis = Date.parse(withTimezone);
  return Number.isFinite(millis) ? new Date(millis).toISOString() : null;
}

export function parseSePayTransaction(payload: unknown): SePayTransaction {
  if (
    payload == null || typeof payload !== "object" || Array.isArray(payload)
  ) {
    throw new Error("SEPAY_PAYLOAD_INVALID");
  }
  const rawPayload = payload as JsonRecord;
  const id = numberField(rawPayload.id);
  const gateway = stringField(rawPayload.gateway);
  const accountNumber = stringField(rawPayload.accountNumber);
  const transferType = stringField(rawPayload.transferType)?.toLowerCase();
  const transferAmount = numberField(rawPayload.transferAmount);

  if (
    id == null || !Number.isSafeInteger(id) || id <= 0 ||
    gateway == null || accountNumber == null ||
    (transferType !== "in" && transferType !== "out") ||
    transferAmount == null || !Number.isSafeInteger(transferAmount) ||
    transferAmount <= 0
  ) {
    throw new Error("SEPAY_PAYLOAD_UNSUPPORTED");
  }

  return {
    id,
    gateway,
    accountNumber,
    subAccount: stringField(rawPayload.subAccount),
    transferType,
    transferAmount,
    paymentCode: stringField(rawPayload.code),
    referenceCode: stringField(rawPayload.referenceCode),
    transactionAt: parseTransactionAt(
      stringField(rawPayload.transactionDate),
    ),
    rawPayload,
  };
}
