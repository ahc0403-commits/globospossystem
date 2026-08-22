# Direct-order cashier arrival alert contract

Date: 2026-08-21
Scope: in-app arrival notice only while a cashier views `/cashier` or
`/cashier/direct-orders`

## Frozen existing-alert boundary

The direct arrival implementation is created only under
`lib/features/direct_order/`, the two route builders, and the additive direct
alert migration/test. It does not import, refactor, share a cursor with, or
change any existing SePay, bank-transfer, kitchen, emergency, push, voice, or
acknowledgement implementation.

The following SHA-256 manifest is a release stop condition:

```text
9db6f26a839d5e2744e9430b7589e8dcb838df67844a413c8fb4a0858a74707c  lib/main.dart
bb62d51f93c474461783312d3d0acfbad2a087df122b650bdc3f1637cb447017  lib/features/cashier/cashier_screen.dart
e3cdc57c2a55ab67d948f7445fe18cac7305957153ef63ffff38b139bc5b5fa6  lib/features/kitchen/kitchen_screen.dart
c2be5ad39d75cd26df46682bed90423d39fc147b0841fe140d0beacc9a628d71  lib/core/services/bank_transfer_alert_coordinator.dart
05a1dbf45971c9c28437f52e970ce1ab6dfbec29f291188648cf50e708028dff  lib/core/services/bank_transfer_alert_service.dart
a3de8b7c4da0280e89678ffbdd9e129d010803e8c06eac56b430b641b33d23e9  lib/core/services/bank_transfer_alert_sound.dart
6f833898be76ef2dcbfe589aa209ff1233fa1c36e24915ede1e6db813a1b5f8c  lib/core/services/bank_transfer_alert_sound_io.dart
bdfb5a24dabd6ec2c3b28ac9923a6d3d3b1866e15c731cb7762b962377fcae2d  lib/core/services/bank_transfer_alert_sound_web.dart
29cd654015c80ce8124710eb2bd25661587f835a7e50c885cca13cb18cc3752c  lib/core/services/sepay_push_notification_service.dart
c2dfb84820152026b0089086238268a19aa87280a5a1c24aa3bf4df40bb4789a  lib/core/services/emergency_order_voice_message.dart
a6860655bdde88ce6ec26603b1cf3ec7d8eb5e8b5ec9310130bb5332f5a250b6  test/bank_transfer_alert_coordinator_test.dart
1ac2246575678ba45c14eafa8bc08e8c9d9e07027ec7bcd69964dd9f6dad52e4  test/sepay_bank_transfer_contract_test.dart
4b6ecfc6d031b749c9195a0788c279bf61e63f617feadaf590cb91c7da296411  test/kitchen_operational_attention_contract_test.dart
1a03192f4fa6dfc92b13be2963a6fa80e37c67146b47651e867be62a34654504  lib/l10n/app_localizations.dart
6c7dd42c5250f4719b0666fe8c5da8a36dac5c5e6cb58a22af8e018b4f18604c  lib/l10n/app_localizations_ko.dart
f4d729295cbdab9cc048c6fc3235855336eb9f113e191bc0e6b31fe2539a3e13  lib/l10n/app_localizations_vi.dart
2aa6fcafc6e561a27862b54cc4debb0eb9dd95b7d07e8acc455b549989324082  lib/l10n/app_localizations_en.dart
```

## Event and cursor semantics

- Only a committed INSERT into `direct_order_requests` emits domain
  `direct_orders`, source `direct_order_requests`, event `INSERT` through the
  existing payload-free `pos_live_events` mechanism.
- Every request is inserted in `awaiting_quote`. Submit replay inserts nothing.
  Quote, chat, proof, approve, reject, cancel, dispatch, UPDATE, DELETE, and a
  rolled-back submit emit no arrival event.
- Realtime is an invalidation signal only. The cashier-only, store-scoped
  `direct_order_arrival_alerts_after` RPC returns exact
  `(request_id, created_at, state)` cursor rows and current `awaiting_quote`
  count. It returns no locale, customer, address, menu, chat, proof, bank, or
  Grab payload.
- A first device call establishes the latest server cursor without replaying
  historical orders. Later pages are strictly ordered by `(created_at,id)`.
  The device persists its cursor by store before displaying a batch. If a
  direct request INSERT signal arrives while that first baseline is being
  established, the host drains after the captured cursor and shows a one-order
  fallback if the INSERT was already absorbed into the baseline. A new order
  cannot disappear in the initialization window.
- Realtime and mixed-domain `*` signals drain the cursor after a 500ms burst
  window. An independent 10-second poll is the safety fallback. Route changes,
  reconnects, and app restarts consume the same device/store cursor.
- Display, close, and `View order` never mutate a request. The action only
  navigates to `/cashier/direct-orders`.

## Receiver locale and sound

The host is enabled only for role `cashier`; admin and kitchen routes do not
receive this alert. Copy uses `Localizations.localeOf(context)` at render time,
never `request.locale`.

| Copy | KO | VI | EN |
|---|---|---|---|
| title | 배달 주문 | Đơn giao hàng | Delivery order |
| singular | 새 배달 주문이 들어왔습니다. | Có đơn giao hàng mới. | A new delivery order has arrived. |
| plural | 새 배달 주문 `{count}`건이 들어왔습니다. | Có `{count}` đơn giao hàng mới. | `{count}` new delivery orders have arrived. |
| chip | 배달 주문 · `{count}` | Đơn giao hàng · `{count}` | Delivery order · `{count}` |
| action | 주문 확인 | Xem đơn | View order |

The sound is a separate, short, non-verbal direct-order chime implemented in
new conditional web/IO files. Audio preparation or autoplay failure cannot
block the visual notice, cursor, polling, or other alert systems.

## Observability and privacy

The host exposes only stage, success, batch count, and elapsed milliseconds for
`initialize`, `drain`, `display`, and `chime`. Metrics must not include request
IDs, customer/request locale, address, chat, proof, phone, bank, or Grab data.
Errors remain contained in the route host and are retried by the safety poll.
