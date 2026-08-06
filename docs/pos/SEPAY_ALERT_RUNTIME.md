# SePay payment alert runtime

This path is limited to SePay Test Mode until the device checks below pass. MSB
account linking, bank authentication, OTP, and Live webhook activation are not
part of this change.

## Runtime paths

- Web and an open Windows POS drain every matched incoming transaction in
  `received_at + provider_transaction_id` order. The cursor is persisted per
  store, realtime is the fast signal, and an app-root two-second poll repairs
  missed realtime events even after the operator leaves the cashier route.
- Android uses a high-priority, non-collapsible FCM data message. Its background
  handler shows a locked-screen receipt and plays the bundled Vietnamese token
  audio sequentially.
- iOS/iPadOS uses a mutable APNs alert. The notification service extension
  composes the amount-specific CAF file in the shared app-group
  `Library/Sounds` directory before delivery.
- macOS uses APNs/FCM while the native POS is installed and permission is
  granted; its background handler uses the same queued bundled audio player.
- Browsers cannot guarantee speech while the browser or device is suspended.
  Use the installed POS/companion runtime on any device that must announce while
  locked.

Only the `cashier` role starts these listeners or registers a push token; Photo
Objet and the other POS roles do not. Native logout or role changes delete the
device's FCM token. Each installation is private to its user and store. The
delivery ledger records `queued`, `processing`, provider `accepted`, UI `seen`,
and audio `spoken` states. Push tokens are service-role-only.

## External configuration required before a device test

Provision Firebase Cloud Messaging and upload the Apple APNs key in Firebase.
Do not commit credential files. Supply these public client identifiers as
build-time Dart defines:

- `FIREBASE_API_KEY`
- `FIREBASE_APP_ID`
- `FIREBASE_MESSAGING_SENDER_ID`
- `FIREBASE_PROJECT_ID`
- `FIREBASE_IOS_BUNDLE_ID` for Apple builds

Set `FIREBASE_SERVICE_ACCOUNT_JSON` as a Supabase Edge Function secret. Keep the
existing `CRON_SECRET` identical between Supabase Vault and Edge secrets. Never
print either value in logs or chat.

Apple Developer provisioning must enable Push Notifications and the app group
`group.com.globosvn.globosPosSystem` for both Runner and
BankTransferNotificationService.

## Test Mode release gate

1. Deploy only from a clean, exact `main` SHA after the required GitHub Actions
   check succeeds, using `scripts/deploy_pos_production.sh`.
2. Confirm the cashier banner no longer reports that locked-device
   notification setup is missing.
3. Send at least three consecutive Test Mode incoming transfers for the mapped
   BunsikClub Binh Thanh VA. Do not use a real transfer.
4. On web, Windows, macOS, Android phone/tablet, and iPhone/iPad, verify each
   amount appears once and is spoken once in Vietnamese and in original order.
5. Lock each native device and repeat. Confirm Android/iOS/macOS notifications,
   amount speech, store isolation, no duplicate speech, and delivery ledger
   transitions. Windows must keep the installed POS running when the session is
   locked.
6. Inspect the webhook and dispatcher logs without exposing payload secrets.
   Confirm retries do not create duplicate `(transaction_id, device_id)` rows.

Do not enable the Live webhook or perform an MSB bank transfer until every Test
Mode check passes.
