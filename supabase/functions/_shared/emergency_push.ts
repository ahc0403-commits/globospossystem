export interface EmergencyPushDelivery {
  id: string;
  eventId: string;
  restaurantId: string;
  orderId: string;
  stationType: "kitchen" | "tray" | "floor";
  floorLabel: string | null;
  stage: string;
  pushToken: string;
  attemptCount: number;
}

export function mapEmergencyPushDelivery(
  row: Record<string, unknown>,
): EmergencyPushDelivery {
  const stationType = String(row.station_type ?? "");
  if (!["kitchen", "tray", "floor"].includes(stationType)) {
    throw new Error("EMERGENCY_PUSH_STATION_INVALID");
  }
  const pushToken = String(row.push_token ?? "");
  if (pushToken.length < 16) throw new Error("EMERGENCY_PUSH_TOKEN_INVALID");
  return {
    id: String(row.id),
    eventId: String(row.event_id),
    restaurantId: String(row.restaurant_id),
    orderId: String(row.order_id),
    stationType: stationType as EmergencyPushDelivery["stationType"],
    floorLabel: row.floor_label == null ? null : String(row.floor_label),
    stage: String(row.stage),
    pushToken,
    attemptCount: Math.max(1, Number(row.attempt_count) || 1),
  };
}

export function buildEmergencyFcmMessage(delivery: EmergencyPushDelivery) {
  const stationLabel = delivery.stationType === "kitchen"
    ? "Bếp"
    : delivery.stationType === "tray"
    ? "Khay"
    : `Tầng ${delivery.floorLabel ?? ""}`.trim();
  return {
    message: {
      token: delivery.pushToken,
      data: {
        type: "emergency_fulfillment",
        event_id: delivery.eventId,
        restaurant_id: delivery.restaurantId,
        order_id: delivery.orderId,
        station_type: delivery.stationType,
        floor_label: delivery.floorLabel ?? "",
        stage: delivery.stage,
        url: delivery.stationType === "kitchen" ? "/kitchen" : "/emergency",
      },
      webpush: {
        headers: { Urgency: "high", TTL: "300" },
        notification: {
          title: `Công việc mới · ${stationLabel}`,
          body: "Mở màn hình để kiểm tra đơn hàng.",
          tag: delivery.eventId,
          renotify: true,
        },
        fcm_options: {
          link: delivery.stationType === "kitchen" ? "/kitchen" : "/emergency",
        },
      },
    },
  };
}
