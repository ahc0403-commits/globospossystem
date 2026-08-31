import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'supabase/migrations/20260831010000_kds_realtime_v2.sql',
  ).readAsStringSync();
  final provider = File(
    'lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart',
  ).readAsStringSync();
  final sync = File(
    'lib/features/emergency_fulfillment/kds_realtime_sync.dart',
  ).readAsStringSync();
  final screen = File(
    'lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart',
  ).readAsStringSync();

  group('additive database rollout', () {
    test('defaults every store to legacy and never auto-activates', () {
      expect(migration, contains("DEFAULT 'legacy'"));
      expect(migration, contains("COALESCE(rollout.mode, 'legacy')"));
      expect(
        RegExp(
          r'INSERT INTO public\.kds_realtime_rollouts',
        ).allMatches(migration),
        hasLength(1),
        reason: 'Only the explicit super-admin rollout RPC may insert a flag.',
      );
      expect(
        migration,
        contains('KDS_REALTIME_MIGRATION_MUST_NOT_AUTO_ACTIVATE'),
      );
      expect(migration, contains('KDS_REALTIME_SHADOW_REQUIRED'));
      expect(migration, contains('KDS_REALTIME_SHADOW_PARITY_REQUIRED'));
      expect(migration, isNot(contains('DROP TABLE public.emergency_')));
      expect(migration, isNot(contains('ALTER TABLE public.emergency_')));
      expect(
        migration,
        isNot(contains('CREATE OR REPLACE FUNCTION public.emergency_record_')),
      );
    });

    test(
      'uses durable revisions, coalescing, and deferred private Broadcast',
      () {
        expect(
          migration,
          contains('CREATE TABLE IF NOT EXISTS public.kds_store_revisions'),
        );
        expect(
          migration,
          contains('CREATE TABLE IF NOT EXISTS public.kds_change_log'),
        );
        expect(migration, contains('UNIQUE (restaurant_id, revision)'));
        expect(migration, contains('FOR UPDATE'));
        expect(migration, contains("'source:' || txid_current()::text"));
        expect(
          migration,
          contains(
            'CREATE CONSTRAINT TRIGGER kds_change_log_broadcast_trigger',
          ),
        );
        expect(migration, contains('DEFERRABLE INITIALLY DEFERRED'));
        expect(migration, contains("'kds_change'"));
        expect(migration, contains('true\n      );'));
        expect(migration, contains('kds_private_broadcast_read'));
        expect(
          migration,
          contains('public.kds_can_access_topic(realtime.topic())'),
        );
      },
    );

    test(
      'captures established event sources and eventless source reductions',
      () {
        expect(migration, contains('ON public.emergency_fulfillment_events'));
        expect(migration, contains('ON public.emergency_fulfillment_sessions'));
        expect(migration, contains('ON public.order_items'));
        expect(migration, contains('OLD.quantity'));
        expect(migration, contains('OLD.combo_components'));
        expect(migration, contains('ON public.fulfillment_mode_changes'));
        expect(migration, contains("NEW.stage = 'floor_direct_ready'"));
        expect(migration, contains('NEW.leftover_packaging_request_id'));
        expect(migration, contains("v_action.action_kind = 'revert'"));
      },
    );

    test('v2 commands delegate to the unchanged authoritative RPCs', () {
      for (final legacyRpc in [
        'emergency_record_progress',
        'emergency_record_combo_component_progress',
        'emergency_record_floor_direct_progress',
        'emergency_complete_route_order_stage',
        'emergency_revert_route_order_action',
        'emergency_advance_leftover_packaging',
      ]) {
        expect(migration, contains('public.$legacyRpc('));
      }
      expect(migration, contains('get_kds_bootstrap_v2'));
      expect(migration, contains('get_kds_changes_v2'));
      expect(migration, contains('get_kds_high_watermark_v2'));
      expect(migration, contains('get_kds_ticket_v2'));
      expect(migration, contains('observe_kds_shadow_v2'));
      expect(migration, contains('get_kds_shadow_health'));
    });
  });

  group('client compatibility gates', () {
    test(
      'legacy and shadow retain the established subscriptions and polling',
      () {
        expect(
          provider,
          contains('if (syncConfig.mode == KdsSyncMode.active) return;'),
        );
        expect(provider, contains('_subscribeLegacy(storeId);'));
        expect(provider, contains("'observe_kds_shadow_v2'"));
        expect(provider, contains('Timer.periodic(_handoffRefreshInterval'));
        expect(provider, contains('const KdsSyncConfig.legacy()'));
      },
    );

    test('active mode uses private Broadcast plus durable delta recovery', () {
      expect(sync, contains('RealtimeChannelConfig(private: true)'));
      expect(sync, contains("event: 'kds_change'"));
      expect(sync, contains('gateway.loadChanges(_cursor)'));
      expect(sync, contains('batch.bootstrapRequired'));
      expect(sync, contains('gateway.loadConfig()'));
      expect(provider, contains('await kdsSync.catchUp();'));
      expect(screen, contains('.refreshFromSignal()'));
    });

    test('active commands do not wait for a full snapshot reload', () {
      expect(provider, contains("'kds_record_progress_v2'"));
      expect(provider, contains("'kds_complete_order_v2'"));
      expect(provider, contains("'kds_revert_order_v2'"));
      expect(provider, contains("'kds_advance_leftover_v2'"));
      expect(
        provider,
        contains('if (_syncMode != KdsSyncMode.active) {\n        await load'),
      );
      expect(provider, contains('_applyAuthoritativeProgress'));
    });
  });
}
