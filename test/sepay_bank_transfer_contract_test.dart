import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_sound.dart';

void main() {
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
    final cursor = BankTransferAlertCursor(startedAt: startedAt);
    final historical = _alert(
      id: 'historical',
      receivedAt: startedAt.subtract(const Duration(seconds: 1)),
    );
    final current = _alert(
      id: 'current',
      receivedAt: startedAt.add(const Duration(seconds: 1)),
    );

    expect(cursor.shouldNotify(historical), isFalse);
    expect(cursor.shouldNotify(current), isTrue);
    expect(cursor.shouldNotify(current), isFalse);
  });

  test('first transaction received after cashier mount is not swallowed', () {
    final startedAt = DateTime.parse('2026-08-05T10:00:00Z');
    final cursor = BankTransferAlertCursor(startedAt: startedAt);

    expect(
      cursor.shouldNotify(
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
      final cashier = File(
        'lib/features/cashier/cashier_screen.dart',
      ).readAsStringSync();
      final webSound = File(
        'lib/core/services/bank_transfer_alert_sound_web.dart',
      ).readAsStringSync();
      final nativeSound = File(
        'lib/core/services/bank_transfer_alert_sound_io.dart',
      ).readAsStringSync();

      expect(cashier, contains('Timer.periodic('));
      expect(cashier, contains('_showLatestBankTransferAlert(storeId)'));
      expect(cashier, contains('cursor.shouldNotify(alert)'));
      expect(
        cashier,
        contains('_bankTransferAlertSoundService.play(amount: alert.amount)'),
      );
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

  test('production deploy exposes only the HMAC-protected SePay endpoint', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    expect(deploy, contains('functions deploy sepay-webhook --no-verify-jwt'));

    final edge = File(
      'supabase/functions/sepay-webhook/index.ts',
    ).readAsStringSync();
    expect(edge, contains('x-sepay-signature'));
    expect(edge, contains('x-sepay-timestamp'));
    expect(edge, contains('SEPAY_SIGNATURE_INVALID'));
    expect(edge, contains('return json({ success: true })'));
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
