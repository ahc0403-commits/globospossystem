# Direct-order viewer locale contract

Authority: the current Flutter direct-order surfaces, direct public Edge
boundary, and direct SQL migration. Supported locale codes are exactly `ko`,
`vi`, and `en`.

## Locale ownership

Locale belongs to the person viewing a screen, not to an order.

| Surface | Locale authority |
|---|---|
| Customer storefront, status, and chat | the customer's current app locale |
| Cashier direct-order queue/detail/chat | that cashier device's current app locale |
| Direct-delivery kitchen board | that kitchen device's current app locale |
| Direct analytics and settings | that operator device's current app locale |

Every direct surface exposes the existing `LanguageSwitcher`. It reuses
`LocaleController` and its device-local SharedPreferences value, so switching a
route, refreshing, or reopening the app retains the viewer's selection. No
role, route, session, or order payload is allowed to overwrite it.

`direct_order_sessions.locale` and `direct_order_requests.locale` record the
customer locale used at session/request time. They support customer recovery
and the target language for cashier free-text translation. They are never passed to cashier, kitchen, admin menu/message,
or alert rendering.

## Server boundary

- `create_session` defaults an omitted locale to `vi` for backward-compatible
  clients, but rejects any supplied value other than `ko`, `vi`, or `en`.
- `submit.payload.locale` is required and rejects every other value before any
  request write. Session and request database CHECK constraints independently
  enforce the same set.
- Customer and staff text messages preserve the exact author-entered body.
  A server queue translates customer text into Vietnamese and cashier text into
  the customer request locale through OpenAI Responses. UI locale remains
  device-owned; translations are additive and do not block chat transport.
- Google autocomplete, details, and reverse-geocode calls receive the current
  customer viewer locale. An invalid supplied locale is a fixed
  `INVALID_REQUEST`; it is never silently coerced.
- There is no staff-locale field or staff-locale mutation API. Staff locale is
  entirely the existing viewer/device app state.

## Immutable localized names

Customer menu/category labels use the current customer locale's immutable
`name_ko`, `name_vi`, or `name_en` storefront response.

Request items persist all three names at submit time. Cashier detail selects
from that snapshot using the cashier viewer locale. Manual approval copies all
three names additively to the direct fulfillment ticket item; kitchen selects
from that approval snapshot using the kitchen viewer locale and never re-reads
the live menu. `display_name_vi` remains unchanged for compatibility.

The direct-only name helper falls back to the preserved Vietnamese/compatibility
name only for old or malformed data. A request's locale is not an input to this
helper.

## Translation boundary

Fixed database codes are data, not display copy. Recognized direct system
message codes are localized at render time with `DirectOrderCopy` and therefore
change immediately when that viewer changes locale.

Customer and cashier free-text chat preserves the exact original `body`.
The UI shows an available translation for its current locale and offers an
original-text toggle. Pending or failed translations show the original and a
localized status. Customer notes, item requests, and cashier quote notes follow
the same rule. Fixed codes and menu-name snapshots retain their existing
localization paths.

These values remain exact and are not machine-translated:

- cashier rejection reason unless it is a recognized fixed code;
- Google/provider place names and formatted address returned for the selected
  customer locale;
- customer name, phone, detailed address, structured refund account;
- Grab tracking URL and bank/audit identifiers.

The isolated new-delivery cashier alert follows the same receiver rule: its
title/body/action use the cashier viewer locale at display time. Customer
request locale and PII must not be included in the alert event. Existing POS
alerts are outside this contract and remain unchanged.

## Verification matrix

The local contract covers all customer `ko/vi/en` x cashier `ko/vi/en` pairs,
all three kitchen/admin viewer locales, immediate re-render from the current
locale, exact chat-original preservation across viewer locales, Edge/SQL
allowlist rejection, and approval-time KO/VI/EN ticket snapshots.

## 2026-10-06 customer and packing additions

`DirectOrderCopy` localizes category All/empty/overflow directions, independent
screenshot send/retry/change, picker/upload/reconciliation progress, accepted-photo
status, status-refresh failure/retry, and the already-transferred hint in KO/VI/EN.
Category names use the existing locale snapshot with IDs/selection unchanged.
Failure messages use the current viewer locale; raw technical codes are hidden.
Missing diner count now asks for a staff check. Staff/customer packing summaries
continue to use N diners / N utensil sets, never menu quantity.

Paper ESC/POS uses Vietnamese ASCII `SO NGUOI: N`, `DUNG CU: N BO`; missing counts
use `CHUA NHAP` / `CAN KIEM TRA`. Digital receipt/PDF content retains its existing
Vietnamese receipt policy (`Số người`, `Dụng cụ`), including 100 sets.

## Customer experience locale additions — 2026-10-06

The three display stages, details, item request controls and notification settings use the current customer viewer locale. Cashier templates use that cashier viewer's locale and preserve customer-entered names, address and notes verbatim. The edited draft can be copied manually. Sending free text enqueues automatic translation; original text, monetary values, names, and negations are preserved. Attachments and structured financial fields are not sent to the translation service.

Push-device locale is registered from the customer's current selection and refreshed on page resume or locale change without prompting for permission. Background notification copy comes from that device locale, not the staff device or order locale. `DIRECT_ORDER_PICKUP_READY` and `DIRECT_ORDER_DRIVER_HANDOFF` system messages render via the current viewer locale in chat. Supported codes remain exactly `ko`, `vi`, `en`.

## 2026-10-10 asynchronous translation

`direct-order-translation-dispatcher` claims up to 10 texts in one lease and sends
one strict-schema Responses request. `OPENAI_API_KEY` is an Edge secret, never a
Flutter define. Missing key configuration leaves jobs pending without consuming
retries. Transient failures retry up to five times; staff can retry failed jobs.
The default model is `gpt-4.1-mini-2025-04-14`; the server-only
`DIRECT_ORDER_TRANSLATION_MODEL` secret can select another compatible model.
Numeric tokens must remain exact. `store:false` disables Responses history
storage; it does not assert zero provider retention. The minute scheduler and
existing status polling determine when translations become visible.
