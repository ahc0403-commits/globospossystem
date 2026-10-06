export type DirectOrderPushOutcome =
  | "sent"
  | "retry"
  | "invalid_token"
  | "failed";
export interface DirectOrderPushDelivery {
  id: string;
  leaseId: string;
  eventId: string;
  eventKind: "pickup_ready" | "driver_handoff";
  requestId: string;
  referenceCode: string;
  slug: string;
  storeName: string;
  locale: "ko" | "vi" | "en";
  token: string;
  tokenHash: string;
}

export function mapDirectOrderPush(
  row: Record<string, unknown>,
): DirectOrderPushDelivery {
  if (
    !["pickup_ready", "driver_handoff"].includes(String(row.event_kind)) ||
    !["ko", "vi", "en"].includes(String(row.locale)) ||
    !/^[a-z0-9][a-z0-9-]{2,62}$/.test(String(row.slug)) ||
    typeof row.push_token !== "string" || row.push_token.length < 16
  ) {
    throw new Error("DIRECT_ORDER_PUSH_ROW_INVALID");
  }
  return {
    id: String(row.id),
    leaseId: String(row.lease_id),
    eventId: String(row.event_id),
    eventKind: row.event_kind as DirectOrderPushDelivery["eventKind"],
    requestId: String(row.request_id),
    referenceCode: String(row.reference_code),
    slug: String(row.slug),
    storeName: String(row.store_name),
    locale: row.locale as DirectOrderPushDelivery["locale"],
    token: row.push_token,
    tokenHash: String(row.token_hash),
  };
}

export function buildDirectOrderFcmMessage(
  delivery: DirectOrderPushDelivery,
  origin: string,
) {
  const base = new URL(origin);
  if (base.protocol !== "https:" || base.username || base.password) {
    throw new Error("DIRECT_ORDER_PUSH_ORIGIN_INVALID");
  }
  const pickup = delivery.eventKind === "pickup_ready";
  const body = delivery.locale === "ko"
    ? pickup
      ? "고객님의 주문 준비가 완료되었습니다. 매장 카운터에서 수령해 주세요."
      : "고객님의 주문이 배달 기사에게 전달되었으며 현재 배송 중입니다."
    : delivery.locale === "en"
    ? pickup
      ? "Your order is ready. Please collect it at the store counter."
      : "Your order has been handed to the delivery driver and is on its way."
    : pickup
    ? "Đơn hàng đã chuẩn bị xong. Vui lòng nhận tại quầy cửa hàng."
    : "Đơn hàng đã được giao cho tài xế và đang trên đường giao.";
  const title = `${delivery.storeName} · #${delivery.referenceCode}`;
  const url = new URL(`/#/order/${delivery.slug}`, base).href;
  return {
    message: {
      token: delivery.token,
      data: {
        type: "direct_order_customer",
        event_id: delivery.eventId,
        event_kind: delivery.eventKind,
        request_id: delivery.requestId,
        title,
        body,
        url,
      },
      webpush: {
        headers: { Urgency: "high", TTL: "300" },
        notification: { title, body, tag: delivery.eventId, data: { url } },
        fcm_options: { link: url },
      },
    },
  };
}

export function directOrderPushOutcome(
  status: number,
  body: Record<string, unknown>,
): DirectOrderPushOutcome {
  if (status >= 200 && status < 300) {
    return typeof body.name === "string" ? "sent" : "retry";
  }
  const error = body.error as
    | { details?: { errorCode?: string }[] }
    | undefined;
  if (
    error?.details?.some((detail) =>
      detail.errorCode === "UNREGISTERED" ||
      detail.errorCode === "SENDER_ID_MISMATCH"
    )
  ) return "invalid_token";
  return status === 401 || status === 429 || status >= 500 ? "retry" : "failed";
}
