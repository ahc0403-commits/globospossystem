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
and audit only. They are never passed to cashier, kitchen, admin menu/message,
or alert rendering.

## Server boundary

- `create_session` defaults an omitted locale to `vi` for backward-compatible
  clients, but rejects any supplied value other than `ko`, `vi`, or `en`.
- `submit.payload.locale` is required and rejects every other value before any
  request write. Session and request database CHECK constraints independently
  enforce the same set.
- Customer and staff text-message actions require the sender's current
  `ko`/`vi`/`en` viewer locale. Translation is executed only by the Edge
  function with its server-held Google key; browser clients never receive the
  key or write translated columns directly.
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

Customer and cashier text chat preserves the exact original in `body` and
stores server-generated `body_ko`, `body_vi`, and `body_en` copies atomically.
The current viewer locale selects the displayed copy. The source-locale copy
must equal the original exactly. If either provider translation fails, the send
fails closed and no partial message row is written. Older text rows without
translations continue to display their original body.

These values remain exact and are never machine-translated:

- cashier rejection reason unless it is a recognized fixed code;
- Google/provider place names and formatted address returned for the selected
  customer locale;
- customer name, phone, detailed address, item note, and customer note;
- Grab tracking URL and bank/audit identifiers.

The isolated new-delivery cashier alert follows the same receiver rule: its
title/body/action use the cashier viewer locale at display time. Customer
request locale and PII must not be included in the alert event. Existing POS
alerts are outside this contract and remain unchanged.

## Verification matrix

The local contract covers all customer `ko/vi/en` x cashier `ko/vi/en` pairs,
all three kitchen/admin viewer locales, immediate re-render from the current
locale, exact chat-original preservation with viewer-selected translations,
provider failure without partial writes, Edge/SQL allowlist rejection, and
approval-time KO/VI/EN ticket snapshots.
