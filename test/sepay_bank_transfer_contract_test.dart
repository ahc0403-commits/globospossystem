import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/layout/platform_info.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_sound.dart';

void main() {
  test('bank transfer alerts are enabled only on Windows hosts', () {
    final previous = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = previous);

    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        PlatformInfo.supportsBankTransferAlerts,
        platform == TargetPlatform.windows,
        reason: '$platform must not receive a bank-transfer alert',
      );
    }
  });

  test('SePay alert model parses PostgREST number representations', () {
    final alert = BankTransferAlert.fromJson({
      'transaction_id': '3431af72-2e82-46f0-abcd-499613b874bb',
      'provider_transaction_id': '92704',
      'amount': 350000.0,
      'payment_code': 'GBA1B2C3D4',
      'gateway': 'Vietcombank',
      'transaction_at': '2026-08-05T10:00:00Z',
      'received_at': '2026-08-05T10:00:01Z',
    });

    expect(alert.providerTransactionId, 92704);
    expect(alert.amount, 350000);
    expect(alert.paymentCode, 'GBA1B2C3D4');
  });

  test('alert cursor ignores history and accepts new transactions once', () {
    final startedAt = DateTime.parse('2026-08-05T10:00:00Z');
    final cursor = BankTransferAlertCursor(
      receivedAt: startedAt,
      providerTransactionId: 0,
    );
    final historical = _alert(
      id: 'historical',
      receivedAt: startedAt.subtract(const Duration(seconds: 1)),
    );
    final current = _alert(
      id: 'current',
      receivedAt: startedAt.add(const Duration(seconds: 1)),
    );

    expect(cursor.isBefore(historical), isFalse);
    expect(cursor.isBefore(current), isTrue);
    cursor.advance(current);
    expect(cursor.isBefore(current), isFalse);
  });

  test('first transaction received after cashier mount is not swallowed', () {
    final startedAt = DateTime.parse('2026-08-05T10:00:00Z');
    final cursor = BankTransferAlertCursor(
      receivedAt: startedAt,
      providerTransactionId: 0,
    );

    expect(
      cursor.isBefore(
        _alert(
          id: 'first-live',
          receivedAt: startedAt.add(const Duration(milliseconds: 1)),
        ),
      ),
      isTrue,
    );
  });

  test('bank transfer amount is announced in Vietnamese only', () {
    expect(
      vietnameseBankTransferMessage(93456),
      'Chuyển khoản, 93456 đồng đã được nhận.',
    );
  });

  test('Vietnamese audio tokens pronounce contextual amount digits', () {
    expect(vietnameseBankTransferAudioTokens(1000), [
      'prefix',
      'mot',
      'nghin',
      'suffix',
    ]);
    expect(vietnameseBankTransferAudioTokens(1005), [
      'prefix',
      'mot',
      'nghin',
      'khong',
      'tram',
      'le',
      'nam',
      'suffix',
    ]);
    expect(vietnameseBankTransferAudioTokens(10015), [
      'prefix',
      'muoi',
      'nghin',
      'khong',
      'tram',
      'muoi',
      'lam',
      'suffix',
    ]);
    expect(vietnameseBankTransferAudioTokens(93456), [
      'prefix',
      'chin',
      'muoi_hang_chuc',
      'ba',
      'nghin',
      'bon',
      'tram',
      'nam',
      'muoi_hang_chuc',
      'sau',
      'suffix',
    ]);
    expect(vietnameseBankTransferAudioTokens(100001), [
      'prefix',
      'mot',
      'tram',
      'nghin',
      'khong',
      'tram',
      'le',
      'mot',
      'suffix',
    ]);
    expect(vietnameseBankTransferAudioTokens(499000000), [
      'prefix',
      'bon',
      'tram',
      'chin',
      'muoi_hang_chuc',
      'chin',
      'trieu',
      'suffix',
    ]);
  });

  test('every Vietnamese speech token has a bundled MP3 asset', () {
    for (final token in vietnameseBankTransferAudioAssetTokens) {
      expect(
        File('assets/audio/bank_transfer_vi/$token.mp3').existsSync(),
        isTrue,
        reason: 'Missing bundled audio token: $token',
      );
    }
  });

  test(
    'cashier keeps realtime primary with polling and web sound fallback',
    () {
      final coordinator = File(
        'lib/core/services/bank_transfer_alert_coordinator.dart',
      ).readAsStringSync();
      final main = File('lib/main.dart').readAsStringSync();
      final webSound = File(
        'lib/core/services/bank_transfer_alert_sound_web.dart',
      ).readAsStringSync();
      final nativeSound = File(
        'lib/core/services/bank_transfer_alert_sound_io.dart',
      ).readAsStringSync();

      expect(main, contains('BankTransferAlertCoordinator('));
      expect(main, contains('PlatformInfo.supportsBankTransferAlerts'));
      expect(main, contains("auth.role == 'cashier'"));
      expect(main, contains('storeId: alertStoreId'));
      expect(main, isNot(contains('syncStore(')));
      expect(coordinator, contains('Timer.periodic('));
      expect(coordinator, contains('posLiveEventsProvider(storeId)'));
      expect(coordinator, contains('_drain(storeId)'));
      expect(coordinator, contains('cursor.isBefore(alert)'));
      expect(coordinator, contains('fetchAfter('));
      expect(coordinator, contains('cursor.advance(alert)'));
      expect(coordinator, contains('_soundService.play(amount: alert.amount)'));
      expect(webSound, contains("_assetBasePath = 'assets/assets/audio/"));
      expect(webSound, contains('context.decodeAudioData(bytes)'));
      expect(webSound, contains('context.createBufferSource()'));
      expect(webSound, contains('web.SpeechSynthesisUtterance('));
      expect(webSound, contains("..lang = 'vi-VN'"));
      expect(webSound, contains('speech.speak(utterance)'));
      expect(webSound, contains('web.AudioContext()'));
      expect(webSound, contains('_scheduleTone'));
      expect(nativeSound, contains('AudioPlayer()'));
      expect(
        nativeSound,
        contains('vietnameseBankTransferAudioTokens(amount)'),
      );
      expect(nativeSound, contains('AssetSource('));
      expect(nativeSound, contains('player.onPlayerComplete.first'));
      expect(nativeSound, contains('SystemSoundType.alert'));

      final windowsCmake = File('windows/CMakeLists.txt').readAsStringSync();
      expect(windowsCmake, contains('if(TARGET audioplayers_windows_plugin)'));
      expect(
        windowsCmake,
        contains('_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'),
      );
    },
  );

  test('SePay SQL keeps raw payload private and emits store-scoped events', () {
    final sql = File(
      'supabase/migrations/20260805120000_sepay_bank_transfer_alerts.sql',
    ).readAsStringSync();

    expect(sql, contains('REVOKE ALL ON public.sepay_transactions'));
    expect(sql, contains('p_raw_payload jsonb'));
    expect(sql, contains("emit_pos_live_event('bank_transfer')"));
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.sepay_bank_accounts'),
    );
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.sepay_transactions'),
    );
    expect(
      sql,
      contains(
        'CREATE UNIQUE INDEX IF NOT EXISTS '
        'sepay_bank_accounts_provider_identity_idx',
      ),
    );
    expect(sql, contains('WHEN (NEW.restaurant_id IS NOT NULL'));
    expect(sql, contains('ON CONFLICT (sepay_transaction_id) DO NOTHING'));
  });

  test('ordered SePay alert RPC drains every cursor successor', () {
    final sql = File(
      'supabase/migrations/20260806100000_sepay_ordered_payment_alerts.sql',
    ).readAsStringSync();

    expect(sql, contains('get_sepay_payment_alerts_after'));
    expect(sql, contains('txn.received_at > p_after_received_at'));
    expect(sql, contains('txn.sepay_transaction_id > COALESCE('));
    expect(
      sql,
      contains('ORDER BY txn.received_at ASC, txn.sepay_transaction_id ASC'),
    );
    expect(sql, contains('user_accessible_stores(auth.uid())'));
    expect(sql, contains('LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)'));

    final verification = File(
      'scripts/verify_sepay_ordered_payment_alerts.sql',
    ).readAsStringSync();
    expect(verification, contains('SEPAY_ORDERED_ALERTS_VERIFY_FAILED'));
    expect(verification, contains('user_accessible_stores(auth.uid())'));
    expect(
      verification,
      contains('ORDER BY txn.received_at ASC, txn.sepay_transaction_id ASC'),
    );
    expect(verification, contains("has_function_privilege('authenticated'"));
    expect(verification, contains("has_function_privilege('anon'"));
  });

  test('production deploy keeps SePay limited to the HMAC endpoint', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    expect(deploy, contains('functions deploy sepay-webhook --no-verify-jwt'));
    expect(deploy, isNot(contains('functions deploy sepay-alert-dispatcher')));
    expect(deploy, contains('SEPAY_WEBHOOK_SECRET'));

    final edge = File(
      'supabase/functions/sepay-webhook/index.ts',
    ).readAsStringSync();
    expect(edge, isNot(contains('FIREBASE_SERVICE_ACCOUNT_JSON')));
    expect(edge, isNot(contains('firebase')));
    expect(edge, contains('x-sepay-signature'));
    expect(edge, contains('x-sepay-timestamp'));
    expect(edge, contains('SEPAY_SIGNATURE_INVALID'));
    expect(edge, contains('return json({ success: true })'));
  });

  test('SePay delivery ledger isolates devices and retries stale claims', () {
    final sql = File(
      'supabase/migrations/'
      '20260806110000_sepay_alert_device_delivery_ledger.sql',
    ).readAsStringSync();

    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.sepay_alert_devices'),
    );
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.sepay_alert_deliveries'),
    );
    expect(sql, contains('REVOKE ALL ON public.sepay_alert_devices'));
    expect(sql, contains('REVOKE ALL ON public.sepay_alert_deliveries'));
    expect(sql, contains('user_accessible_stores(auth.uid())'));
    expect(sql, contains("device.user_id = auth.uid()"));
    expect(sql, contains("sepay_alert_devices.push_provider = 'fcm'"));
    expect(sql, contains("EXCLUDED.push_provider = 'polling'"));
    expect(sql, contains("delivery.status = 'processing'"));
    expect(sql, contains("now() - interval '5 minutes'"));
    expect(sql, contains('FOR UPDATE OF delivery SKIP LOCKED'));
    expect(sql, contains('UNIQUE (transaction_id, device_id)'));
    expect(sql, contains('sepay-alert-dispatcher-every-minute'));
    expect(sql, contains('vault.decrypted_secrets'));
    expect(sql, contains("WHERE name = 'cron_secret'"));

    final verification = File(
      'scripts/verify_sepay_alert_device_delivery_ledger.sql',
    ).readAsStringSync();
    expect(verification, contains('SEPAY_ALERT_LEDGER_VERIFY_FAILED'));
    expect(verification, contains('table_row.relrowsecurity'));
    expect(verification, contains('UNIQUE (transaction_id, device_id)'));
    expect(verification, contains('device.user_id = auth.uid()'));
    expect(verification, contains('FOR UPDATE OF delivery SKIP LOCKED'));
    expect(verification, contains("device.push_provider = ''fcm''"));
    expect(verification, contains('sepay_alert_delivery_enqueue_trigger'));
    expect(verification, contains('sepay-alert-dispatcher-every-minute'));
  });

  test('server accepts and enqueues alerts only for Windows polling', () {
    final sql = File(
      'supabase/migrations/20260806120000_sepay_windows_only_alerts.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_sepay_windows_only_alerts.sql',
    ).readAsStringSync();

    expect(sql, contains("p_platform <> 'windows'"));
    expect(sql, contains("p_push_provider <> 'polling'"));
    expect(sql, contains("device.platform = 'windows'"));
    expect(sql, contains("device.push_provider = 'polling'"));
    expect(
      sql,
      contains("WHERE jobname = 'sepay-alert-dispatcher-every-minute'"),
    );
    expect(verification, contains('SEPAY_WINDOWS_ONLY_ALERTS_VERIFY_FAILED'));
    expect(verification, contains("platform <> 'windows'"));
    expect(verification, contains("push_provider <> 'polling'"));
  });

  test('SePay test VA maps only to BunsikClub Binh Thanh', () {
    final sql = File(
      'supabase/migrations/'
      '20260805160000_sepay_bunsikclub_binh_thanh_mapping.sql',
    ).readAsStringSync();

    expect(sql, contains('8bc9eef5-dcd5-46b1-b931-23f77132322c'));
    expect(sql, contains('BunsikClub Binh Thanh'));
    expect(sql, contains('9358674202'));
    expect(sql, contains('SBSEPAYOA465N89VHYK'));
    expect(sql, contains('SEPAY_TEST_STORE_MISMATCH'));
    expect(sql, contains('ON CONFLICT DO NOTHING'));

    final verification = File(
      'scripts/verify_sepay_bunsikclub_binh_thanh_mapping.sql',
    ).readAsStringSync();
    expect(verification, contains('BunsikClub Binh Thanh'));
    expect(verification, contains('9358674202'));
    expect(verification, contains('SBSEPAYOA465N89VHYK'));
    expect(verification, contains('account.is_active = true'));
    expect(verification, contains('SEPAY_TEST_STORE_MAPPING_VERIFY_FAILED'));
  });

  test('live MBBank account maps only to BunsikClub Binh Thanh', () {
    final sql = File(
      'supabase/migrations/'
      '20260807150000_sepay_mb_bunsikclub_binh_thanh_mapping.sql',
    ).readAsStringSync();

    expect(sql, contains('8bc9eef5-dcd5-46b1-b931-23f77132322c'));
    expect(sql, contains('BunsikClub Binh Thanh'));
    expect(sql, contains("'MBBank'"));
    expect(sql, contains('SEPAY_MB_STORE_MISMATCH'));
    expect(sql, contains('SEPAY_MB_ACCOUNT_ALREADY_MAPPED'));
    expect(sql, contains('ON CONFLICT DO NOTHING'));

    final verification = File(
      'scripts/verify_sepay_mb_bunsikclub_binh_thanh_mapping.sql',
    ).readAsStringSync();
    expect(verification, contains('BunsikClub Binh Thanh'));
    expect(verification, contains("'mbbank'"));
    expect(verification, contains('account.is_active = true'));
    expect(verification, contains('SEPAY_MB_MAPPING_VERIFY_FAILED'));
  });

  test('mobile push is disabled for Windows-only bank transfer alerts', () {
    final push = File(
      'lib/core/services/sepay_push_notification_service.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();

    expect(push, contains('static bool get isNativePushPlatform => false'));
    expect(main, isNot(contains('SePayPushNotificationService')));
    expect(cashier, isNot(contains('SePayPushNotificationService')));
    expect(cashier, isNot(contains('sepay_push_readiness_banner')));
  });
}

BankTransferAlert _alert({required String id, required DateTime receivedAt}) {
  return BankTransferAlert(
    transactionId: id,
    providerTransactionId: 1,
    amount: 1000,
    gateway: 'Vietcombank',
    receivedAt: receivedAt,
  );
}
