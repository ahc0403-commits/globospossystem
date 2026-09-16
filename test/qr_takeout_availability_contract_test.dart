import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/features/settings/promotion_settings_card.dart';
import 'package:globos_pos_system/features/settings/promotion_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

class _FakePromotionService extends PromotionService {
  QrTakeoutAvailability setting = const QrTakeoutAvailability(
    configuredEnabled: false,
    effectiveEnabled: false,
  );
  bool? savedEnabled;

  @override
  Future<List<StorePromotion>> list(String storeId) async => const [];

  @override
  Future<QrTakeoutAvailability> getQrTakeoutAvailability(
    String storeId,
  ) async => setting;

  @override
  Future<QrTakeoutAvailability> setQrTakeoutAvailability({
    required String storeId,
    required bool enabled,
    DateTime? resumeAt,
  }) async {
    savedEnabled = enabled;
    setting = QrTakeoutAvailability(
      configuredEnabled: enabled,
      effectiveEnabled: enabled,
      resumeAt: resumeAt,
    );
    return setting;
  }
}

void main() {
  const migrationPath =
      'supabase/migrations/20260916140000_qr_takeout_availability.sql';

  test('QR menu and BM setting models parse takeout availability', () {
    final menu = QrOrderMenu.fromJson({
      'store_name': 'BunsikClub',
      'table_number': '8',
      'floor_label': '1F',
      'takeout_enabled': false,
      'categories': <Object>[],
      'items': <Object>[],
    });
    final setting = QrTakeoutAvailability.fromJson({
      'configured_enabled': false,
      'effective_enabled': false,
      'resume_at': '2026-09-19T17:00:00Z',
    });

    expect(menu.isTakeoutEnabled, isFalse);
    expect(setting.configuredEnabled, isFalse);
    expect(setting.effectiveEnabled, isFalse);
    expect(setting.resumeAt, isNotNull);
  });

  test('migration pauses now, schedules resume, and guards stale clients', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('qr_takeout_enabled'));
    expect(sql, contains('qr_takeout_resume_at'));
    expect(sql, contains('-- production-gate: self-verifying'));
    expect(sql, contains("timestamptz '2026-09-20 00:00:00+07'"));
    expect(sql, contains('get_qr_takeout_availability'));
    expect(sql, contains('set_qr_takeout_availability'));
    expect(sql, contains('require_pos_admin_actor_for_store'));
    expect(sql, contains("'qr_takeout_availability_changed'"));
    expect(sql, contains("'takeout_enabled', v_effective"));
    expect(sql, contains("RAISE EXCEPTION 'QR_TAKEOUT_UNAVAILABLE'"));
    expect(sql, contains("'menu', 'restaurants', 'UPDATE'"));
    expect(
      sql,
      contains(
        'qr_place_order_pre_takeout_availability(text,jsonb,uuid,boolean,uuid)',
      ),
    );
    expect(sql, contains('FROM PUBLIC, anon, authenticated'));
  });

  testWidgets('BM can enable QR takeout from promotion settings', (
    tester,
  ) async {
    final service = _FakePromotionService();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: PromotionSettingsCard(storeId: 'store-id', service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_qr_takeout_control')),
      findsOneWidget,
    );
    expect(find.text('일시 중지'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_qr_takeout_schedule_resume')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('settings_qr_takeout_toggle')));
    await tester.pumpAndSettle();

    expect(service.savedEnabled, isTrue);
    expect(find.text('사용 가능'), findsOneWidget);
  });
}
