# Direct delivery UI implementation specification

Date: 2026-08-21
Framework: existing Flutter Web application
Status: Active implementation specification

## Concept references

- `concepts/customer-menu-address.png`: customer menu and the two-path address sheet
- `concepts/customer-quote-chat.png`: quote, VietQR, proof, chat, progress, Grab link
- `concepts/cashier-direct-orders.png`: separate cashier request inbox and approval dialog
- `concepts/kitchen-direct-orders.png`: separate direct-delivery kitchen board
- `concepts/direct-order-analytics.png`: additive direct-delivery analytics

The generated restaurant names, menu data, bank data, dates, maps, and metrics are layout samples only. Runtime data is authoritative. Generated images are never shipped as interactive UI.

## Color and surface lock

- Customer/cashier/analytics canvas: `#F5F7FA`
- Surface: true white `#FFFFFF`
- Primary text: `#111827`
- Secondary text: `#6B7280`
- Border: `#E5E7EB`
- Action/focus: `#2563EB`
- Success: `#059669`
- Warning: `#D97706`
- Danger: `#DC2626`
- Kitchen shell: `#111820`, rail `#17202B`, panel `#202A37`
- Kitchen ticket paper: `#F8F4EA`

Use existing `PosColors`, `PosTerminalColors`, `PosDensity`, `PosMetrics`, `PosStatusPalette`, and Pretendard. Do not introduce a parallel theme.

## Typography and geometry

- UI family: existing Pretendard configuration.
- VND totals and elapsed time use tabular figures.
- Customer body: 14–16 logical pixels; amount anchor: 28–32.
- Cashier/analytics chrome: 12–16; approval amount: 24–28.
- Kitchen order reference and timer: 24–32; item rows: at least 18.
- Minimum interactive target: 48 logical pixels.
- Existing token radii only; avoid nested rounded panels.

## Customer surface

### Allowed primary labels

- `메뉴`, `장바구니`, `주소 검색`, `지도에서 선택`, `상세주소`, `이름`, `전화번호`
- `이 기기에 주소 저장`, `위치 확인`, `배송비`, `최종 결제금액`, `계좌이체`
- `입금 증빙 보내기`, `입금 증빙을 보내도 주문은 자동 확정되지 않습니다`
- `매장에서 입금을 확인한 뒤 주문이 주방으로 전달됩니다`
- `메시지 보내기`, `Grab에서 배송 확인`

Equivalent KO/VI/EN localization is required; no operational string is hard-coded.

### Viewer locale boundary

- Customer, cashier, kitchen, analytics, and settings surfaces always expose
  the existing KO/VI/EN `LanguageSwitcher`, including compact widths.
- Each surface renders from `Localizations.localeOf(context)`. A request's
  recorded locale never controls a staff surface.
- Customer menu uses the current customer locale snapshot. Cashier and kitchen
  use their current viewer locale against the immutable request/ticket
  KO/VI/EN snapshots.
- Fixed system codes, status, errors, and direct alerts re-render immediately
  after locale change. Chat, address, customer/item notes, and provider place
  text remain exactly as entered/returned and are not machine-translated.
- The detailed authority is `DIRECT_ORDER_LOCALE_CONTRACT.md`.

### Component families

- Compact store header and language control
- Open menu list with category rail, menu row, image, price, quantity stepper
- Persistent cart amount action
- One address sheet with two equal entry paths
- Map/pin frame, normalized-address row, detailed-address/contact form
- Quote breakdown and amount anchor
- VietQR account panel
- Proof uploader with progress/error/retry
- Append-only chat timeline and composer
- Fulfillment timeline and Grab link action

The 390px layout is one vertical scroll surface. Sticky controls must not hide focused fields or the final chat item.

## Cashier surface

- Header with store context, enabled/paused state, unread count, refresh.
- Desktop: 300px request list, flexible detail, 360px chat.
- Phone/tablet: list-to-detail navigation; no squeezed three-column layout.
- Request list stays table/row based with status tabs and keyset pagination.
- Detail owns map/address, menu, quote, proof, SePay evidence, dispatch and audit.
- Chat owns append-only messages only.
- `입금 확인 및 주문 확정` is the sole approval action and requires one final confirmation dialog.
- SePay is always labeled as supporting evidence and cannot approve.
- While a cashier views `/cashier` or `/cashier/direct-orders`, a compact
  direct-only arrival banner uses that cashier's current KO/VI/EN locale. It
  shows a pending-count chip, dismiss, and `View order` navigation only. A
  500ms burst becomes one plural banner and one non-verbal chime.

## Kitchen surface

- Dedicated dark route, visually related to current terminal tokens but state-independent.
- Filters: waiting, preparing, ready, dispatched/completed.
- Fixed-width paper tickets show reference, elapsed time, paid/direct identity, items/options, and exactly one next-state action.
- Never display address, phone, proof, bank, chat, delivery fee, or Grab cost.
- Existing KDS remains reachable without sharing providers or ticket mutations.

## Analytics surface

- Reuse existing date/store controls visually without replacing current Reports.
- Restrained KPI band for direct revenue, order count, charged delivery fee, actual Grab cost/variance.
- Hour × weekday heatmap, region table, coarse grid, financial trend, top items.
- Direct delivery and Deliberry remain visibly separate.
- Exact address/contact/precise pin never appears.
- Cells below the configured privacy threshold are hidden with an explanatory note.

## Icon inventory

Use existing Material icons with consistent outline/fill treatment:

- Navigation/back: `arrow_back`
- Language: `language`
- Cart: `shopping_cart_outlined`
- Address search: `search`
- Map pin: `location_on_outlined`
- Current position: `my_location`
- Edit/copy/delete: standard outlined actions
- Proof: `image_outlined`, upload and retry icons
- Chat/send: `chat_bubble_outline`, `send`
- Paid/success: `check_circle_outline`
- Warning: `warning_amber_rounded`
- Kitchen pending/preparing/ready: timer, soup-kitchen, task-alt metaphors
- Grab link: delivery/moped metaphor plus `open_in_new`

Do not introduce raster icons or a second icon library.

## Responsive checkpoints

- Customer: 390×844, 768×1024, 1024×768, 1440×900
- Cashier: 390×844 list/detail, 768×1024 two-stage, 1024×768 two-pane, 1440×900 three-pane
- Kitchen: 768×1024 two columns, 1024×768 three columns, 1440×900 four columns/activity rail
- Analytics: 768×1024 stacked sections, 1024×768 two columns, 1440×900 full composition

## Motion and accessibility

- Motion is limited to state transitions, upload progress, new-message reveal, and focus feedback.
- Respect reduced-motion settings.
- Status is never communicated by color alone.
- Every field has a visible label and error/help text.
- Keyboard focus order follows visual order and returns from dialogs correctly.

## 2026-10-06 customer navigation, screenshots and packing

Source implementation only; production migration/web/Print Station deployment and
physical printer verification require separate evidence.

- Menu view keeps a horizontal category bar below the progress tabs, outside the
  vertical menu viewport. `All` is selected initially. Only populated categories
  from the storefront response are shown, in server order. A selection filters
  locally and resets vertical scrolling; repeat selection and quantity changes
  preserve position. Category IDs, cart, notes and diner input survive locale and
  address navigation. Removed categories fall back to `All`. Desktop arrows and
  mobile swipes expose overflow; full labels remain available through tooltips.
- The quote card exposes `Bank transfer details` and `Send transfer screenshot`
  separately. The account dialog owns QR/account/reference details and close.
  Screenshot preview identifies the order and amount. Picker/preview cancellation
  makes no upload request; the picker is guarded from its first click.
- Failed attempts retain bytes, MIME and exact request/quote/review/path in screen
  memory. Retry resumes that attempt; an uncertain Storage response is reconciled
  by committing its existing path first. Photo replacement is unavailable until
  the uncertain result is resolved. Successful commit remains sent even if status
  refresh fails, with a separate status refresh action. Staff resubmission presents
  its reason and no-repeat-transfer warning directly, including locked old quotes.
  Advanced/terminal states do not request a new screenshot.
- All direct delivery/pickup forms (payment, kitchen, floor, tray, confirmation,
  handoff) put `SO NGUOI: N` / `DUNG CU: N BO`
  above items; utensil sets are bold and double height. Missing/invalid counts on
  identified direct orders require a staff check. Ordinary dine-in guest counts
  never imply utensil sets. Cashier/kitchen packing counts are emphasized.
- Native payment-detail printing reads authorized single-order packing context,
  without enqueuing a duplicate job. New direct digital snapshots and their 80mm
  PDF include the count. Receipt text follows the existing Vietnamese policy.
  Old digital/print snapshots remain immutable; a new reprint uses current counts.

Behavior tests: `direct_delivery_storefront_widget_test.dart`,
`direct_order_proof_retry_test.dart`, `receipt_builder_contract_test.dart`,
`wifi_printer_service_test.dart`, `digital_receipt_pdf_service_test.dart`, and
`direct_order_receipt_packing_contract_test.sql`.

## Customer and cashier feedback implementation — 2026-10-06

The customer hero, order history, and three-step progress use **확인 대기 / 결제 완료 / 완료**. Detailed preparation/ready/handoff labels remain secondary. Cancelled, rejected, and expired orders show their exception labels rather than a completed progress bar. Payment proof submission is still waiting for cashier confirmation; ready and driver handoff remain paid, not completed.

The reference line opens `DirectOrderDetailsSheet`, displaying persisted item names, quantities, unit prices, line amounts, item notes, order reference/time, quote totals, service charge, delivery fee mode, VAT, payment and refund information. Menu prices/line amounts are before tax; the quoted menu total includes tax. An unavailable snapshot is identified, not rebuilt from today's menu. Opening the sheet makes no additional item requests.

The 2026-10-07 detail correction also shows delivery/pickup mode, diner count and
utensil sets, stored recipient/phone, delivery and detailed address (plus stored
district/ward), and whole-order instructions. Whole-order and item instructions
are separate emphasized blocks and preserve multiline input. Staff detail reads
the SQL item `item_note` field; customer snapshots use the public `note` field.
Pickup contact does not invent a delivery address. Legacy missing diner counts
require a staff check; missing/purged customer snapshots say unavailable. Empty
instructions explicitly say none. Proof attachments and customer chat remain in
their existing selected-order conversation, without copying secrets or attachment
storage paths into the details panel.

After adding an item, customers can edit a 300-character request below its menu card and in the cart. The request applies to every unit of that cart line; distinct unit requests require separate orders with the present cart model. Notes survive category, locale and address navigation and are submitted through the existing item `note` contract.

The bell opens notification settings. Permission is requested only by the explicit enable action. When supported/configured, customer web push persists after closing the page; permission denial/configuration failure retain status/chat fallback. Pickup ready and actual driver handoff create separate, deduplicated events. Tray packing completion is ready, without pretending a driver received the order.

Cashier default filters are all/waiting/paid/completed, with detailed filters in an expandable section and visible refund exceptions. Chat templates populate an editable draft, never send automatically, and capture the selected order. Quote templates require a stored quote; the fee draft requires staff to confirm the current amount. Copying the draft supports the requested manual Google Translate workflow.

## 2026-10-10 cashier reconciliation and translation

The receipt dialog accepts the actual bank receipt, displays any excess as a
refund amount, and requires a bank reference and explicit receipt comparison.
The payment panel requests the server-calculated food balance. Excess refund,
cancellation refund, and pickup/delivery refund use a shared photo evidence and
actual-payment confirmation dialog. Customers enter their refund bank/account/
holder and open the resulting transfer proof from their order's support card.

Store-prepaid delivery is the default for new delivery quotes. Positive driver
cash handoff uses the same evidence/confirmation control. Cashier detail and
closing show driver payout, cash recovery, and customer cash refund separately.
Administrators can append extra payouts or recovery; stored payout amounts stay
immutable. The closing denomination dialog subtracts all these cash movements.

Chat, order notes, item requests, and quote notes show available viewer-locale
translations and an original-text toggle. Pending/failed translations preserve
the visible original. A failed translation can be retried by the cashier.

## 2026-10-10 mobile customer payment visibility

The customer status surface keeps the current payment amount above the scrolling
conversation and the message composer below it. Navigation tabs collapse while
the phone keyboard is open. The three-step progress is compact and horizontal.
Sending a message brings that message into view without moving the pinned amount.
The latest quote message renders an amount card with amount-detail and transfer
actions; earlier quote messages retain their stored amount and cannot open a
payment action. A current quote card is still shown if its message is absent
from the returned history. Quote sounds remain deduplicated; the persistent
amount/card replaces the transient quote snackbar.

Payment and amount details open a mobile bottom sheet. An open sheet follows
the current order snapshot, updates its amount/QR when the quote changes, and
removes transfer actions when payment becomes ineligible or enters review.
Existing proof selection, preview, retries and cashier approval remain in use.

Confirmed underpayments use the same chat card, pinned amount and bottom sheet.
The amount to transfer comes from server `food_due`, with the original quote
and confirmed `food_received` shown separately. Before a stored balance charge
exists, the customer sees the shortage and an instructions-pending notice with
no transfer QR. An active balance charge opens a QR for that shortage and the
existing charge-scoped proof uploader. `review`, `paid`, `void`, exception and
superseded balance charges cannot request another transfer. Additional delivery
charges use the same card presentation. Opening these views adds no API calls.

### 2026-10-10 customer mobile progress (supersedes three customer stages)

The same order/chat screen shows a compact current fulfillment card above chat.
Payment is a separate badge. Detailed progress and packing/provider/financial
information expand on demand and also remain available in order details.
The cashier's existing three filter groups stay unchanged.

Customer stages: store reviewing → awaiting payment → checking transfer → food
preparation → food cooked / packing → packed / awaiting driver → with driver /
on the way → delivered. Pickup uses ready for pickup / collected. Cancellation,
rejection and expiry take priority. Cooking requires complete KDS quantities;
packing requires ready, handoff requires the existing dispatch workflow. Normal
completion closes customer access/polling; unsettled refunds and evidence access
remain supported, according to server `support.access_open`.

HTTPS shipping links have explicit open and copy actions, plus a selectable exact
URL. The card, legacy grab_link and URLs in ordinary chat share the component.
Link opening failures retain copy/manual selection. Contact-only delivery has no
invented tracking link. URLs are never translated.

Diners initially show 1 (range 1..100). Disposable utensils have independent
receive-per-diner / no-utensils choices. Food containers are always included.
Opt-out persists after diner edits and flows to staff packing and receipts.
Cooking and packing chat/push notices deduplicate by request/event; no new
cashier button or extra action is introduced.
