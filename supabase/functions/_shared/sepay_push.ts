export interface SePayAlertDelivery {
  deliveryId: string;
  transactionId: string;
  restaurantId: string;
  deviceId: string;
  platform: "web" | "windows" | "macos" | "android" | "ios";
  pushProvider: "fcm" | "apns" | "web_push" | "polling";
  pushToken: string;
  amount: number;
  paymentCode: string | null;
  receivedAt: string;
  attemptCount: number;
}

export interface FirebaseServiceAccount {
  projectId: string;
  clientEmail: string;
  privateKey: string;
  tokenUri: string;
}

export function parseFirebaseServiceAccount(
  raw: string,
): FirebaseServiceAccount {
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  const projectId = String(parsed.project_id ?? "").trim();
  const clientEmail = String(parsed.client_email ?? "").trim();
  const privateKey = String(parsed.private_key ?? "").replace(/\\n/g, "\n");
  const tokenUri = String(
    parsed.token_uri ?? "https://oauth2.googleapis.com/token",
  ).trim();
  if (!projectId || !clientEmail || !privateKey.includes("PRIVATE KEY")) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT_INVALID");
  }
  return { projectId, clientEmail, privateKey, tokenUri };
}

export function mapClaimedDelivery(
  row: Record<string, unknown>,
): SePayAlertDelivery {
  const amount = Number(row.amount);
  const attemptCount = Number(row.attempt_count);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new Error("SEPAY_ALERT_AMOUNT_INVALID");
  }
  return {
    deliveryId: String(row.delivery_id),
    transactionId: String(row.transaction_id),
    restaurantId: String(row.restaurant_id),
    deviceId: String(row.device_id),
    platform: String(row.platform) as SePayAlertDelivery["platform"],
    pushProvider: String(
      row.push_provider,
    ) as SePayAlertDelivery["pushProvider"],
    pushToken: String(row.push_token),
    amount,
    paymentCode: row.payment_code == null ? null : String(row.payment_code),
    receivedAt: String(row.received_at),
    attemptCount: Number.isSafeInteger(attemptCount) ? attemptCount : 1,
  };
}

export function buildFcmMessage(delivery: SePayAlertDelivery) {
  if (delivery.pushProvider !== "fcm" || !delivery.pushToken) {
    throw new Error("SEPAY_ALERT_PUSH_PROVIDER_UNSUPPORTED");
  }
  const amountText = `${formatInteger(delivery.amount)} VND`;
  const data = {
    type: "sepay_bank_transfer",
    event_id: delivery.deliveryId,
    transaction_id: delivery.transactionId,
    restaurant_id: delivery.restaurantId,
    amount: String(delivery.amount),
    payment_code: delivery.paymentCode ?? "",
    received_at: delivery.receivedAt,
  };
  const message: Record<string, unknown> = {
    token: delivery.pushToken,
    data,
  };

  if (delivery.platform === "android") {
    message.android = {
      priority: "HIGH",
      ttl: "300s",
    };
  } else if (delivery.platform === "ios" || delivery.platform === "macos") {
    message.apns = {
      headers: {
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      payload: {
        aps: {
          alert: {
            title: "Đã nhận chuyển khoản",
            body: amountText,
          },
          sound: "default",
          "mutable-content": 1,
          "content-available": 1,
          category: "SEPAY_BANK_TRANSFER",
        },
      },
    };
  } else if (delivery.platform === "web") {
    message.webpush = {
      headers: { Urgency: "high", TTL: "300" },
      notification: {
        title: "Đã nhận chuyển khoản",
        body: amountText,
        tag: delivery.deliveryId,
        renotify: true,
      },
    };
  } else {
    throw new Error("SEPAY_ALERT_PLATFORM_UNSUPPORTED");
  }

  return { message };
}

export async function getFirebaseAccessToken(
  account: FirebaseServiceAccount,
  fetcher: typeof fetch = fetch,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = base64UrlJson({ alg: "RS256", typ: "JWT" });
  const claims = base64UrlJson({
    iss: account.clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: account.tokenUri,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  });
  const unsigned = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(account.privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signed = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64UrlBytes(new Uint8Array(signed))}`;
  const response = await fetcher(account.tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) throw new Error(`FIREBASE_OAUTH_FAILED_${response.status}`);
  const body = await response.json() as Record<string, unknown>;
  const token = String(body.access_token ?? "");
  if (!token) throw new Error("FIREBASE_OAUTH_TOKEN_MISSING");
  return token;
}

function formatInteger(value: number): string {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

function base64UrlJson(value: Record<string, unknown>): string {
  return base64UrlBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function base64UrlBytes(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function pemToBytes(pem: string): ArrayBuffer {
  const encoded = pem
    .split(/\r?\n/)
    .filter((line) => !line.trim().startsWith("-----"))
    .join("")
    .replace(/\s/g, "");
  const binary = atob(encoded);
  return Uint8Array.from(
    binary,
    (character) => character.charCodeAt(0),
  ).buffer as ArrayBuffer;
}
