export const MEINVOICE_DEFAULT_AUTH_BASE_URL =
  "https://developer.misa.vn/apis/itg/meinvoice/invoice";
export const MEINVOICE_DEFAULT_API_BASE_URL =
  "https://developer.misa.vn/apis/itg/meinvoice/invoice";

// Official MISA Developer Portal OpenAPI docs:
// https://developer.misa.vn/products-openapi/MEINVOICE
// Auth: POST {base}/token with ClientID + ClientSecret headers and
//       {taxcode, username, password} body (no appid — portal contract).
// Publish: POST {base}/publishing. Templates/status/Download keep their
// legacy names but require the ClientID header alongside the Bearer token.

export type JsonRecord = Record<string, unknown>;

export interface RuntimeConfig {
  dispatchEnabled: boolean;
  batchSize: number;
  tokenRefreshSkewMinutes: number;
}

export interface SellerConfig {
  taxEntityId: string;
  taxCode: string;
  sellerName: string;
  authBaseUrl: string;
  apiBaseUrl: string;
  // MISA Developer Portal ClientID (stored in meinvoice_tax_entity_config.app_id).
  clientId: string;
  invoiceSeries: string;
  integrationStatus: string;
}

export function json(body: JsonRecord, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function asString(value: unknown): string | null {
  if (typeof value === "string" && value.trim().length > 0) {
    return value.trim();
  }
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function roundMoney(value: number): number {
  return Math.round(value * 100) / 100;
}

// VND amounts must be integers: OptionUserDefined declares 0 decimal digits
// for Amount/AmountOC and MISA validates data against the declared digits.
function roundVnd(value: number): number {
  return Math.round(value);
}

function compact<T extends JsonRecord>(value: T): T {
  const cleaned: JsonRecord = {};
  for (const [key, raw] of Object.entries(value)) {
    if (raw === undefined || raw === null) continue;
    if (typeof raw === "string" && raw.trim().length === 0) continue;
    cleaned[key] = raw;
  }
  return cleaned as T;
}

function normalizeBaseUrl(value: unknown, fallback: string): string {
  return (asString(value) ?? fallback).replace(/\/+$/, "");
}

function envSuffixForTaxCode(taxCode: string): string {
  return taxCode.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
}

// Per-legal-entity secrets are mandatory: each tax entity authenticates with
// its own MISA credentials (MISA_MEINVOICE_*_<TAX_CODE>). The unsuffixed
// shared fallback exists only for the single-entity transition window and
// must be enabled explicitly via MISA_MEINVOICE_ALLOW_SHARED_SECRETS=true.
export interface MeInvoiceEntityAuth {
  clientId: string;
  invoiceSeries: string;
  username: string;
  password: string;
  clientSecret: string;
}

export type MeInvoiceEnvReader = (name: string) => string | undefined;

export function resolveMeInvoiceEntityAuth(
  seller: SellerConfig,
  readEnv: MeInvoiceEnvReader = (name) => Deno.env.get(name),
): MeInvoiceEntityAuth {
  assertDispatchReady(seller);
  const suffix = envSuffixForTaxCode(seller.taxCode);
  const entityUsername = asString(
    readEnv(`MISA_MEINVOICE_USERNAME_${suffix}`),
  );
  const entityPassword = asString(
    readEnv(`MISA_MEINVOICE_PASSWORD_${suffix}`),
  );
  const entityClientSecret = asString(
    readEnv(`MISA_MEINVOICE_CLIENT_SECRET_${suffix}`),
  );
  const entityCredentials = [
    entityUsername,
    entityPassword,
    entityClientSecret,
  ];
  const entityCredentialCount = entityCredentials.filter(Boolean).length;

  if (entityCredentialCount > 0 && entityCredentialCount < 3) {
    throw new Error("MEINVOICE_ENTITY_CREDENTIAL_INCOMPLETE");
  }

  if (entityCredentialCount === 3) {
    return {
      clientId: seller.clientId,
      invoiceSeries: seller.invoiceSeries,
      username: entityUsername!,
      password: entityPassword!,
      clientSecret: entityClientSecret!,
    };
  }

  if (readEnv("MISA_MEINVOICE_ALLOW_SHARED_SECRETS") !== "true") {
    throw new Error("MEINVOICE_CREDENTIAL_NOT_CONFIGURED");
  }

  const username = asString(readEnv("MISA_MEINVOICE_USERNAME"));
  const password = asString(readEnv("MISA_MEINVOICE_PASSWORD"));
  if (!username || !password) {
    throw new Error("MEINVOICE_CREDENTIAL_NOT_CONFIGURED");
  }
  const clientSecret = asString(readEnv("MISA_MEINVOICE_CLIENT_SECRET"));
  if (!clientSecret) {
    throw new Error("MEINVOICE_CLIENT_SECRET_NOT_CONFIGURED");
  }
  return {
    clientId: seller.clientId,
    invoiceSeries: seller.invoiceSeries,
    username,
    password,
    clientSecret,
  };
}

function parseJwtExpiry(token: string): Date | null {
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const normalized = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(
      normalized.length + ((4 - normalized.length % 4) % 4),
      "=",
    );
    const payload = JSON.parse(atob(padded));
    return typeof payload.exp === "number"
      ? new Date(payload.exp * 1000)
      : null;
  } catch {
    return null;
  }
}

export async function loadRuntimeConfig(supabase: any): Promise<RuntimeConfig> {
  const keys = [
    "meinvoice_dispatch_enabled",
    "meinvoice_dispatch_batch_size",
    "meinvoice_token_refresh_skew_minutes",
  ];
  const { data, error } = await supabase.from("system_config")
    .select("key,value")
    .in("key", keys);
  if (error) throw error;

  const values: Record<string, string> = {};
  for (const row of data ?? []) values[row.key] = row.value;

  return {
    dispatchEnabled: values.meinvoice_dispatch_enabled === "true",
    batchSize: Math.min(
      Math.max(Number(values.meinvoice_dispatch_batch_size ?? 10), 1),
      50,
    ),
    tokenRefreshSkewMinutes: Math.min(
      Math.max(Number(values.meinvoice_token_refresh_skew_minutes ?? 60), 5),
      1440,
    ),
  };
}

export async function loadSellerConfig(
  supabase: any,
  taxEntityId: string,
): Promise<SellerConfig> {
  const { data: entity, error: entityError } = await supabase
    .from("tax_entity")
    .select("id,tax_code,name")
    .eq("id", taxEntityId)
    .single();
  if (entityError || !entity) {
    throw new Error(`MEINVOICE_TAX_ENTITY_NOT_FOUND:${taxEntityId}`);
  }

  const { data: config, error: configError } = await supabase
    .from("meinvoice_tax_entity_config")
    .select(
      "tax_entity_id,auth_base_url,api_base_url,app_id,invoice_series,integration_status",
    )
    .eq("tax_entity_id", taxEntityId)
    .single();
  if (configError || !config) {
    throw new Error(`MEINVOICE_CONFIG_NOT_FOUND:${taxEntityId}`);
  }

  return {
    taxEntityId,
    taxCode: String(entity.tax_code),
    sellerName: String(entity.name ?? ""),
    authBaseUrl: normalizeBaseUrl(
      config.auth_base_url,
      MEINVOICE_DEFAULT_AUTH_BASE_URL,
    ),
    apiBaseUrl: normalizeBaseUrl(
      config.api_base_url,
      MEINVOICE_DEFAULT_API_BASE_URL,
    ),
    clientId: asString(config.app_id) ?? "",
    invoiceSeries: asString(config.invoice_series) ?? "",
    integrationStatus: asString(config.integration_status) ??
      "needs_vendor_activation",
  };
}

export function assertDispatchReady(seller: SellerConfig) {
  if (seller.integrationStatus !== "active") {
    throw new Error(
      `MEINVOICE_INTEGRATION_NOT_ACTIVE:${seller.integrationStatus}`,
    );
  }
  if (!seller.clientId) throw new Error("MEINVOICE_CLIENT_ID_NOT_CONFIGURED");
  if (!seller.invoiceSeries) {
    throw new Error("MEINVOICE_INVOICE_SERIES_NOT_CONFIGURED");
  }
}

export function assertPayloadReady(seller: SellerConfig) {
  if (!seller.invoiceSeries) {
    throw new Error("MEINVOICE_INVOICE_SERIES_NOT_CONFIGURED");
  }
}

export async function getMeInvoiceToken(
  supabase: any,
  seller: SellerConfig,
  refreshSkewMinutes: number,
): Promise<string> {
  const auth = resolveMeInvoiceEntityAuth(seller);

  const now = new Date();
  const refreshAfter = new Date(now.getTime() + refreshSkewMinutes * 60_000);
  const { data: cached, error: cacheError } = await supabase
    .from("meinvoice_token_cache")
    .select("current_token,token_expires_at")
    .eq("tax_entity_id", seller.taxEntityId)
    .maybeSingle();
  if (cacheError) throw cacheError;

  const expiresAt = cached?.token_expires_at
    ? new Date(cached.token_expires_at)
    : null;
  if (cached?.current_token && expiresAt && expiresAt > refreshAfter) {
    return cached.current_token;
  }

  const tokenResponse = await fetch(`${seller.authBaseUrl}/token`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ClientID: auth.clientId,
      ClientSecret: auth.clientSecret,
    },
    body: JSON.stringify({
      taxcode: seller.taxCode,
      username: auth.username,
      password: auth.password,
    }),
  });
  const body = await tokenResponse.json().catch(() => null) as any;
  const token = asString(body?.Data) ?? asString(body?.data?.access_token);
  if (!tokenResponse.ok || body?.Success === false || !token) {
    throw new Error(
      `MEINVOICE_TOKEN_FAILED:${tokenResponse.status}:${
        JSON.stringify(body).slice(0, 500)
      }`,
    );
  }

  const expires = parseJwtExpiry(token) ??
    new Date(now.getTime() + 14 * 24 * 60 * 60 * 1000);
  await supabase.from("meinvoice_token_cache").upsert({
    tax_entity_id: seller.taxEntityId,
    current_token: token,
    token_expires_at: expires.toISOString(),
    last_verified_at: now.toISOString(),
    updated_at: now.toISOString(),
  });
  return token;
}

function vatRateName(rate: number): string {
  if (!Number.isFinite(rate) || rate <= 0) return "0%";
  return `${Math.round(rate * 100) / 100}%`;
}

function vietnamInvoiceDate(value: unknown): string {
  const raw = asString(value);
  const date = raw ? new Date(raw) : new Date();
  const safeDate = Number.isFinite(date.getTime()) ? date : new Date();
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Ho_Chi_Minh",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(safeDate);
  const byType: Record<string, string> = {};
  for (const part of parts) byType[part.type] = part.value;
  return `${byType.year}-${byType.month}-${byType.day}`;
}

function lineItemsForJob(job: JsonRecord): JsonRecord[] {
  const source = Array.isArray(job.line_items_snapshot)
    ? job.line_items_snapshot as JsonRecord[]
    : [];
  return source.map((item, index) => {
    const quantity = Math.max(asNumber(item.quantity, 1), 1);
    const unitPrice = asNumber(item.unit_price, 0);
    const amountWithoutVat = roundVnd(
      asNumber(item.total_amount_ex_tax, unitPrice * quantity),
    );
    const vatAmount = roundVnd(asNumber(item.vat_amount, 0));
    const payAmount = roundVnd(
      asNumber(item.paying_amount_inc_tax, amountWithoutVat + vatAmount),
    );
    const rate = asNumber(item.vat_rate, 0);
    return compact({
      ItemType: 1,
      LineNumber: index + 1,
      SortOrder: index + 1,
      ItemCode: asString(item.order_item_id) ?? `pos-line-${index + 1}`,
      ItemName: asString(item.display_name) ?? asString(item.label) ??
        "POS sale",
      UnitName: "item",
      Quantity: quantity,
      // Ex-tax unit price at 2dp (declared via UnitPriceOCDecimalDigits).
      // Line amounts stay integer VND; exact Quantity*UnitPrice identity is
      // confirmed vendor-side via /invoice/unpublishview before activation.
      UnitPrice: roundMoney(amountWithoutVat / quantity),
      DiscountRate: 0,
      DiscountAmountOC: 0,
      DiscountAmount: 0,
      AmountOC: amountWithoutVat,
      Amount: amountWithoutVat,
      AmountWithoutVATOC: amountWithoutVat,
      AmountWithoutVAT: amountWithoutVat,
      VATRateName: vatRateName(rate),
      VATAmountOC: vatAmount,
      VATAmount: vatAmount,
      AmountAfterTax: payAmount,
    });
  });
}

function taxRateInfo(details: JsonRecord[]): JsonRecord[] {
  const grouped = new Map<string, { amount: number; vat: number }>();
  for (const detail of details) {
    const name = String(detail.VATRateName ?? "0%");
    const current = grouped.get(name) ?? { amount: 0, vat: 0 };
    current.amount += asNumber(detail.AmountWithoutVAT, 0);
    current.vat += asNumber(detail.VATAmount, 0);
    grouped.set(name, current);
  }

  return [...grouped.entries()].map(([VATRateName, totals]) =>
    compact({
      VATRateName,
      AmountWithoutVATOC: roundVnd(totals.amount),
      AmountWithoutVAT: roundVnd(totals.amount),
      VATAmountOC: roundVnd(totals.vat),
      VATAmount: roundVnd(totals.vat),
    })
  );
}

function readVietnameseTriple(value: number, forceFull: boolean): string[] {
  const digits = [
    "không",
    "một",
    "hai",
    "ba",
    "bốn",
    "năm",
    "sáu",
    "bảy",
    "tám",
    "chín",
  ];
  const words: string[] = [];
  const hundred = Math.floor(value / 100);
  const ten = Math.floor((value % 100) / 10);
  const unit = value % 10;

  if (forceFull || hundred > 0) {
    words.push(digits[hundred], "trăm");
    if (ten === 0 && unit > 0) words.push("lẻ");
  }

  if (ten > 1) {
    words.push(digits[ten], "mươi");
    if (unit === 1) words.push("mốt");
    else if (unit === 5) words.push("lăm");
    else if (unit > 0) words.push(digits[unit]);
  } else if (ten === 1) {
    words.push("mười");
    if (unit === 5) words.push("lăm");
    else if (unit > 0) words.push(digits[unit]);
  } else if (unit > 0) {
    words.push(digits[unit]);
  }

  return words;
}

export function vietnameseVndWords(amount: number): string {
  const whole = Math.max(0, Math.round(amount));
  if (whole === 0) return "Không đồng.";

  const scaleNames = ["", "nghìn", "triệu", "tỷ", "nghìn tỷ", "triệu tỷ"];
  const groups: number[] = [];
  let rest = whole;
  while (rest > 0) {
    groups.push(rest % 1000);
    rest = Math.floor(rest / 1000);
  }

  const words: string[] = [];
  for (let index = groups.length - 1; index >= 0; index -= 1) {
    const group = groups[index];
    if (group === 0) continue;
    const forceFull = index < groups.length - 1 && group < 100;
    words.push(...readVietnameseTriple(group, forceFull));
    const scale = scaleNames[index] ?? "";
    if (scale) words.push(scale);
  }

  const sentence = `${words.join(" ")} đồng chẵn.`;
  return sentence.charAt(0).toUpperCase() + sentence.slice(1);
}

export function buildCashRegisterInvoicePayload(
  job: JsonRecord,
  seller: SellerConfig,
): JsonRecord {
  assertPayloadReady(seller);

  const details = lineItemsForJob(job);
  if (details.length === 0) throw new Error("MEINVOICE_LINE_ITEMS_REQUIRED");

  const buyer = (job.buyer_snapshot && typeof job.buyer_snapshot === "object")
    ? job.buyer_snapshot as JsonRecord
    : {};
  const anonymousName = "Nguoi mua khong lay hoa don";
  const receiverEmail = asString(buyer.email);
  const buyerTaxCode = asString(buyer.tax_code) ??
    asString(buyer.tin_cic_household_head_id);
  const buyerLegalName = asString(buyer.unit_name) ??
    asString(buyer.customer_name) ??
    anonymousName;
  const buyerFullName = asString(buyer.buyer_full_name);
  const totalWithoutVat = roundVnd(
    details.reduce(
      (sum, detail) => sum + asNumber(detail.AmountWithoutVAT, 0),
      0,
    ),
  );
  const totalVat = roundVnd(
    details.reduce((sum, detail) => sum + asNumber(detail.VATAmount, 0), 0),
  );
  const totalPayment = roundVnd(totalWithoutVat + totalVat);
  const invDate = vietnamInvoiceDate(job.created_at);

  return {
    SignType: 5,
    InvoiceData: [compact({
      RefID: String(job.id),
      InvSeries: seller.invoiceSeries,
      InvoiceName: "Hóa đơn GTGT khởi tạo từ máy tính tiền",
      InvDate: invDate,
      CurrencyCode: "VND",
      ExchangeRate: 1,
      PaymentMethodName: asString(job.payment_method_snapshot) ?? "Tien mat",
      BuyerCode: asString(buyer.unit_code),
      BuyerTaxCode: buyerTaxCode,
      BuyerLegalName: buyerLegalName,
      BuyerFullName: buyerFullName,
      BuyerAddress: asString(buyer.address),
      BuyerEmail: receiverEmail,
      BuyerPhoneNumber: asString(buyer.phone),
      ContactName: buyerFullName ?? buyerLegalName,
      AccountObjectIdentificationNumber: asString(buyer.buyer_id),
      IsInvoiceCalculatingMachine: true,
      DiscountRate: 0,
      TotalDiscountAmountOC: 0,
      TotalDiscountAmount: 0,
      TotalAmountWithoutVATOC: totalWithoutVat,
      TotalAmountWithoutVAT: totalWithoutVat,
      TotalVATAmountOC: totalVat,
      TotalVATAmount: totalVat,
      TotalAmountOC: totalPayment,
      TotalAmount: totalPayment,
      TotalAmountInWords: vietnameseVndWords(totalPayment),
      TotalSaleAmountOC: totalWithoutVat,
      TotalSaleAmount: totalWithoutVat,
      OriginalInvoiceDetail: details,
      TaxRateInfo: taxRateInfo(details),
      OptionUserDefined: {
        MainCurrency: "VND",
        AmountDecimalDigits: "0",
        AmountOCDecimalDigits: "0",
        UnitPriceOCDecimalDigits: "2",
        UnitPriceDecimalDigits: "2",
        QuantityDecimalDigits: "2",
        CoefficientDecimalDigits: "0",
      },
      IsSendEmail: receiverEmail != null,
      ReceiverName: buyerFullName ?? buyerLegalName,
      ReceiverEmail: receiverEmail,
    })],
  };
}

function invalidPayload(reason: string): never {
  throw new Error(`MEINVOICE_PAYLOAD_INVALID:${reason}`);
}

function requireFiniteNumber(
  missing: Set<string>,
  field: string,
  value: unknown,
  minValue = 0,
) {
  const parsed = asNumber(value, Number.NaN);
  if (!Number.isFinite(parsed) || parsed < minValue) missing.add(field);
}

function requirePositiveNumber(
  missing: Set<string>,
  field: string,
  value: unknown,
) {
  const parsed = asNumber(value, Number.NaN);
  if (!Number.isFinite(parsed) || parsed <= 0) missing.add(field);
}

export function validateCashRegisterInvoicePayload(
  payload: JsonRecord,
): JsonRecord {
  if (!payload || typeof payload !== "object") {
    invalidPayload("payload");
  }

  const missing = new Set<string>();
  if (payload.SignType !== 5) missing.add("SignType");
  const invoices = Array.isArray(payload.InvoiceData)
    ? payload.InvoiceData as JsonRecord[]
    : [];
  if (invoices.length === 0) missing.add("InvoiceData");

  for (const invoice of invoices) {
    if (!invoice || typeof invoice !== "object") {
      missing.add("InvoiceData.item");
      continue;
    }

    for (
      const field of [
        "RefID",
        "InvSeries",
        "InvDate",
        "InvoiceName",
        "CurrencyCode",
        "PaymentMethodName",
        "TotalAmountInWords",
      ]
    ) {
      if (!asString(invoice[field])) missing.add(field);
    }

    for (
      const field of [
        "DiscountRate",
        "TotalDiscountAmountOC",
        "TotalDiscountAmount",
        "TotalAmountWithoutVATOC",
        "TotalAmountWithoutVAT",
        "TotalVATAmountOC",
        "TotalVATAmount",
        "TotalAmountOC",
        "TotalAmount",
        "TotalSaleAmountOC",
        "TotalSaleAmount",
      ]
    ) {
      requireFiniteNumber(missing, field, invoice[field]);
    }

    const details = Array.isArray(invoice.OriginalInvoiceDetail)
      ? invoice.OriginalInvoiceDetail as JsonRecord[]
      : [];
    if (details.length === 0) missing.add("OriginalInvoiceDetail");
    for (const detail of details) {
      if (!asString(detail.ItemName)) {
        missing.add("OriginalInvoiceDetail.ItemName");
      }
      if (detail.ItemType !== 1) {
        missing.add("OriginalInvoiceDetail.ItemType");
      }
      requirePositiveNumber(
        missing,
        "OriginalInvoiceDetail.Quantity",
        detail.Quantity,
      );
      for (
        const field of [
          "UnitPrice",
          "DiscountRate",
          "DiscountAmountOC",
          "DiscountAmount",
          "AmountOC",
          "Amount",
          "AmountWithoutVATOC",
          "AmountWithoutVAT",
          "VATAmountOC",
          "VATAmount",
          "AmountAfterTax",
        ]
      ) {
        requireFiniteNumber(
          missing,
          `OriginalInvoiceDetail.${field}`,
          detail[field],
        );
      }
    }

    const taxRates = Array.isArray(invoice.TaxRateInfo)
      ? invoice.TaxRateInfo as JsonRecord[]
      : [];
    if (taxRates.length === 0) missing.add("TaxRateInfo");
    for (const taxRate of taxRates) {
      if (!asString(taxRate.VATRateName)) {
        missing.add("TaxRateInfo.VATRateName");
      }
      requireFiniteNumber(
        missing,
        "TaxRateInfo.AmountWithoutVATOC",
        taxRate.AmountWithoutVATOC,
      );
      requireFiniteNumber(
        missing,
        "TaxRateInfo.VATAmountOC",
        taxRate.VATAmountOC,
      );
    }

    const options = invoice.OptionUserDefined as JsonRecord | undefined;
    if (!options || typeof options !== "object") {
      missing.add("OptionUserDefined");
    } else {
      for (
        const field of [
          "MainCurrency",
          "AmountDecimalDigits",
          "AmountOCDecimalDigits",
          "UnitPriceOCDecimalDigits",
          "UnitPriceDecimalDigits",
        ]
      ) {
        if (!asString(options[field])) {
          missing.add(`OptionUserDefined.${field}`);
        }
      }
    }
  }

  if (missing.size > 0) invalidPayload([...missing].sort().join(","));
  return payload;
}

// Portal contract: every business call carries the ClientID header next to
// the Bearer token.
function misaApiHeaders(seller: SellerConfig, token: string) {
  return {
    "content-type": "application/json",
    ClientID: seller.clientId,
    authorization: `Bearer ${token}`,
  };
}

export async function publishCashRegisterInvoice(
  seller: SellerConfig,
  token: string,
  payload: JsonRecord,
) {
  const response = await fetch(
    `${seller.apiBaseUrl}/publishing`,
    {
      method: "POST",
      headers: misaApiHeaders(seller, token),
      body: JSON.stringify(payload),
    },
  );
  return {
    ok: response.ok,
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

function parseJsonMaybe(value: unknown): unknown {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

export function parsePublishResult(body: unknown): JsonRecord | null {
  const raw = body as any;
  let data = parseJsonMaybe(
    raw?.publishInvoiceResult ??
      raw?.PublishInvoiceResult ??
      raw?.createInvoiceResult ??
      raw?.CreateInvoiceResult ??
      raw?.Data ??
      raw?.data,
  );
  if (Array.isArray(data) && data.length > 0 && typeof data[0] === "object") {
    return data[0] as JsonRecord;
  }
  if (data && typeof data === "object") return data as JsonRecord;
  return null;
}

export function summarizePublishResponse(body: unknown): JsonRecord {
  const raw = body as any;
  const result = parsePublishResult(body);
  return compact({
    success: typeof raw?.success === "boolean"
      ? raw.success
      : typeof raw?.Success === "boolean"
      ? raw.Success
      : undefined,
    error_code: asString(result?.ErrorCode) ?? asString(raw?.ErrorCode) ??
      asString(raw?.errorCode) ?? asString(raw?.Code),
    transaction_id: asString(result?.TransactionID),
    invoice_series: asString(result?.InvSeries),
    invoice_number: asString(result?.InvNo),
    tax_authority_code: asString(result?.InvCode),
    search_code: asString(result?.TransactionID) ?? asString(result?.InvCode),
  });
}

export async function getMeInvoiceTemplates(
  seller: SellerConfig,
  token: string,
  year = new Date().getFullYear(),
) {
  const url = new URL(`${seller.apiBaseUrl}/templates`);
  url.searchParams.set("invoiceWithCode", "true");
  url.searchParams.set("ticket", "false");
  url.searchParams.set("year", String(year));
  const response = await fetch(url, {
    method: "GET",
    headers: misaApiHeaders(seller, token),
  });
  return {
    ok: response.ok,
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

export async function getCashRegisterInvoiceStatus(
  seller: SellerConfig,
  token: string,
  identifiers: string[],
  inputType = 2,
) {
  const url = new URL(`${seller.apiBaseUrl}/status`);
  url.searchParams.set("invoiceWithCode", "true");
  url.searchParams.set("invoiceCalcu", "true");
  url.searchParams.set("inputType", String(inputType));
  const response = await fetch(url, {
    method: "POST",
    headers: misaApiHeaders(seller, token),
    body: JSON.stringify(identifiers),
  });
  return {
    ok: response.ok,
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

export async function downloadCashRegisterInvoice(
  seller: SellerConfig,
  token: string,
  transactionIds: string[],
  downloadDataType = "Pdf",
) {
  const url = new URL(`${seller.apiBaseUrl}/Download`);
  url.searchParams.set("invoiceWithCode", "true");
  url.searchParams.set("invoiceCalcu", "true");
  url.searchParams.set("downloadDataType", downloadDataType);
  const response = await fetch(url, {
    method: "POST",
    headers: misaApiHeaders(seller, token),
    body: JSON.stringify(transactionIds),
  });
  return {
    ok: response.ok,
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

export async function logMeInvoiceEvent(
  supabase: any,
  jobId: string | null,
  eventType: string,
  description: string,
  options: {
    retryCount?: number | null;
    metadata?: JsonRecord | null;
  } = {},
) {
  await supabase.from("meinvoice_job_events").insert({
    job_id: jobId,
    event_type: eventType,
    description,
    retry_count: options.retryCount ?? null,
    metadata: options.metadata ?? {},
    raw_request: null,
    raw_response: null,
  });
}
