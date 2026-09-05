import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_arrival_alert_host.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_arrival_alert_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_arrival_alert_sound.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _storeId = 'da000000-0000-4000-8000-000000000001';
final _cursor0 = DirectOrderArrivalCursor(
  createdAt: _time0,
  requestId: 'da000000-0000-4000-8000-000000000010',
);
final _time0 = DateTime.utc(2026, 8, 21, 12);

const _frozenAlertFiles = <String, String>{
  'lib/main.dart':
      '9db6f26a839d5e2744e9430b7589e8dcb838df67844a413c8fb4a0858a74707c',
  'lib/features/cashier/cashier_screen.dart':
      '60f007189e40d111d1e302d7719a9156b0cb9aaee8b12f3879b95f17ce5bee3e',
  'lib/features/kitchen/kitchen_screen.dart':
      'e3cdc57c2a55ab67d948f7445fe18cac7305957153ef63ffff38b139bc5b5fa6',
  'lib/core/services/bank_transfer_alert_coordinator.dart':
      'c2be5ad39d75cd26df46682bed90423d39fc147b0841fe140d0beacc9a628d71',
  'lib/core/services/bank_transfer_alert_service.dart':
      '05a1dbf45971c9c28437f52e970ce1ab6dfbec29f291188648cf50e708028dff',
  'lib/core/services/bank_transfer_alert_sound.dart':
      'a3de8b7c4da0280e89678ffbdd9e129d010803e8c06eac56b430b641b33d23e9',
  'lib/core/services/bank_transfer_alert_sound_io.dart':
      '6f833898be76ef2dcbfe589aa209ff1233fa1c36e24915ede1e6db813a1b5f8c',
  'lib/core/services/bank_transfer_alert_sound_web.dart':
      'bdfb5a24dabd6ec2c3b28ac9923a6d3d3b1866e15c731cb7762b962377fcae2d',
  'lib/core/services/sepay_push_notification_service.dart':
      '29cd654015c80ce8124710eb2bd25661587f835a7e50c885cca13cb18cc3752c',
  'lib/core/services/emergency_order_voice_message.dart':
      'c2dfb84820152026b0089086238268a19aa87280a5a1c24aa3bf4df40bb4789a',
  'test/bank_transfer_alert_coordinator_test.dart':
      'a6860655bdde88ce6ec26603b1cf3ec7d8eb5e8b5ec9310130bb5332f5a250b6',
  'test/sepay_bank_transfer_contract_test.dart':
      '1ac2246575678ba45c14eafa8bc08e8c9d9e07027ec7bcd69964dd9f6dad52e4',
  'test/kitchen_operational_attention_contract_test.dart':
        'c3d02484495f7f05ec542b82419681c707f1bb02d52181c6f54c534b6c2399b6',
  'lib/l10n/app_localizations.dart':
      '31f2a9f6dd634f1a21dd1f57c5aebae4dcf098ca06d1779d1b27a9c6a3a3f5fb',
  'lib/l10n/app_localizations_ko.dart':
      '65e98584e779b4e5e9352348308c21a29c45326a868e9f955d852463bcf954a6',
  'lib/l10n/app_localizations_vi.dart':
      'f7bfc3ca19261062d54a8de183bfbeead77601f946145838b678b5304c88a681',
  'lib/l10n/app_localizations_en.dart':
      'fab8e559f8b04fc3f8c87dcaa63913ce192c28c3b932d844aadb2693133cd95f',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('existing POS alert sources tests and generated locale stay exact', () {
    for (final entry in _frozenAlertFiles.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: entry.key);
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        entry.value,
        reason: 'frozen existing alert changed: ${entry.key}',
      );
    }
  });

  test('arrival copy follows cashier locale in all 9 customer pairs', () {
    const expected = {
      'ko': [
        '배달 주문',
        '새 배달 주문이 들어왔습니다.',
        '새 배달 주문 3건이 들어왔습니다.',
        '배달 주문 · 4',
        '주문 확인',
      ],
      'vi': [
        'Đơn giao hàng',
        'Có đơn giao hàng mới.',
        'Có 3 đơn giao hàng mới.',
        'Đơn giao hàng · 4',
        'Xem đơn',
      ],
      'en': [
        'Delivery order',
        'A new delivery order has arrived.',
        '3 new delivery orders have arrived.',
        'Delivery order · 4',
        'View order',
      ],
    };
    for (final customerLocale in ['ko', 'vi', 'en']) {
      for (final cashierLocale in ['ko', 'vi', 'en']) {
        final copy = DirectOrderCopy(cashierLocale);
        expect(
          [
            copy.arrivalAlertTitle,
            copy.arrivalAlertBody(1),
            copy.arrivalAlertBody(3),
            copy.arrivalPendingChip(4),
            copy.viewArrivalOrder,
          ],
          expected[cashierLocale],
          reason: 'customer=$customerLocale cashier=$cashierLocale',
        );
      }
    }
  });

  testWidgets('banner re-renders title body chip and action in viewer locale', (
    tester,
  ) async {
    for (final locale in ['ko', 'vi', 'en']) {
      await tester.pumpWidget(
        _localizedApp(
          locale,
          DirectOrderArrivalAlertBanner(
            count: 2,
            pendingCount: 5,
            onClose: () {},
            onViewOrders: () {},
          ),
        ),
      );
      final copy = DirectOrderCopy(locale);
      expect(find.text(copy.arrivalAlertTitle), findsOneWidget);
      expect(find.text(copy.arrivalAlertBody(2)), findsOneWidget);
      expect(find.text(copy.arrivalPendingChip(5)), findsOneWidget);
      expect(find.text(copy.viewArrivalOrder), findsOneWidget);
    }
  });

  test('cursor persists per store and corrupt cache fails closed', () async {
    final service = DirectOrderArrivalAlertService();
    await service.saveCursor(_storeId, _cursor0);
    expect(await service.loadCursor(_storeId), _cursor0);
    expect(
      await service.loadCursor('da000000-0000-4000-8000-000000000002'),
      isNull,
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'direct_order_arrival_cursor_v1_$_storeId',
      '{broken',
    );
    expect(await service.loadCursor(_storeId), isNull);
    expect(
      preferences.containsKey('direct_order_arrival_cursor_v1_$_storeId'),
      isFalse,
    );
  });

  test('arrival response rejects extra fields and invalid cursor data', () {
    final valid = <String, dynamic>{
      'items': [
        {
          'request_id': 'da000000-0000-4000-8000-000000000011',
          'created_at': '2026-08-21T12:00:01Z',
          'state': 'awaiting_quote',
        },
      ],
      'pending_count': 1,
      'next_cursor': {
        'created_at': '2026-08-21T12:00:01Z',
        'request_id': 'da000000-0000-4000-8000-000000000011',
      },
      'has_more': false,
    };
    expect(DirectOrderArrivalBatch.fromJson(valid).items, hasLength(1));
    expect(
      DirectOrderArrivalCursor.fromJson({
        'created_at': '2026-08-21T12:00:00Z',
        'request_id': '00000000-0000-0000-0000-000000000000',
      }).requestId,
      '00000000-0000-0000-0000-000000000000',
      reason: 'an empty-store server baseline uses the nil UUID sentinel',
    );
    expect(
      () => DirectOrderArrivalBatch.fromJson({...valid, 'locale': 'ko'}),
      throwsFormatException,
    );
    expect(
      () => DirectOrderArrivalBatch.fromJson({
        ...valid,
        'next_cursor': {...valid['next_cursor'] as Map, 'request_id': 'bad'},
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'realtime burst saves cursor then presents once and restart has no duplicate',
    (tester) async {
      final service = _MemoryArrivalService()..saved[_storeId] = _cursor0;
      final sound = _RecordingArrivalSound();
      final events = StreamController<PosLiveEvent>.broadcast();
      final presented = <int>[];
      var viewed = 0;

      await _pumpHost(
        tester,
        service: service,
        sound: sound,
        events: events.stream,
        presented: presented,
        onView: () => viewed += 1,
      );
      service.add(1);
      service.add(2);
      events
        ..add(_event('direct_orders'))
        ..add(_event('direct_orders'));
      await tester.pump(const Duration(milliseconds: 35));
      await tester.pump();

      expect(find.text('Delivery order'), findsOneWidget);
      expect(find.text('2 new delivery orders have arrived.'), findsOneWidget);
      expect(presented, [2]);
      expect(sound.plays, 1);
      expect(
        service.log.lastIndexOf('save'),
        lessThan(service.log.indexOf('present')),
      );

      await tester.tap(find.text('View order'));
      await tester.pump();
      expect(viewed, 1);
      expect(
        find.byKey(const Key('direct_order_arrival_alert_banner')),
        findsNothing,
      );

      events.add(_event('*'));
      await tester.pump(const Duration(milliseconds: 35));
      expect(presented, [2], reason: 'reconnect replay must not alert again');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpHost(
        tester,
        service: service,
        sound: sound,
        events: events.stream,
        presented: presented,
        onView: () => viewed += 1,
      );
      expect(presented, [2], reason: 'route/app restart cursor is durable');

      service.add(3);
      await tester.pump(const Duration(milliseconds: 55));
      await tester.pump();
      expect(presented, [2, 1], reason: '10-second safety poll is injectable');
      expect(sound.plays, 2);
      await events.close();
    },
  );

  testWidgets('insert during first baseline cannot be swallowed', (
    tester,
  ) async {
    final baselineGate = Completer<void>();
    final service = _MemoryArrivalService()..baselineGate = baselineGate;
    final sound = _RecordingArrivalSound();
    final events = StreamController<PosLiveEvent>.broadcast();
    final presented = <int>[];

    await _pumpHost(
      tester,
      service: service,
      sound: sound,
      events: events.stream,
      presented: presented,
    );
    service.add(1);
    events.add(_event('direct_orders'));
    await tester.pump();
    baselineGate.complete();
    await tester.pump(const Duration(milliseconds: 5));
    await tester.pump();

    expect(find.text('Delivery order'), findsOneWidget);
    expect(find.text('A new delivery order has arrived.'), findsOneWidget);
    expect(presented, [1]);
    expect(sound.plays, 1);
    await events.close();
  });

  testWidgets(
    'network storage and sound failures stay contained without duplicate UI',
    (tester) async {
      final service = _MemoryArrivalService()..saved[_storeId] = _cursor0;
      final sound = _RecordingArrivalSound()..fail = true;
      final events = StreamController<PosLiveEvent>.broadcast();
      final presented = <int>[];
      await _pumpHost(
        tester,
        service: service,
        sound: sound,
        events: events.stream,
        presented: presented,
      );

      service.add(1);
      service.failFetches = 1;
      service.failSaves = 1;
      events.add(_event('direct_orders'));
      await tester.pump(const Duration(milliseconds: 35));
      expect(
        find.byKey(const Key('direct_order_arrival_alert_banner')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 125));
      await tester.pump();
      expect(
        find.byKey(const Key('direct_order_arrival_alert_banner')),
        findsOneWidget,
      );
      expect(presented, [1]);
      expect(
        service.saved[_storeId]?.requestId,
        service.arrivals.single.requestId,
      );

      events.add(_event('bank_transfer'));
      await tester.pump(const Duration(milliseconds: 35));
      expect(presented, [1], reason: 'unrelated domains do not drain');
      await events.close();
    },
  );

  testWidgets('disabled/logout host ignores realtime and polling', (
    tester,
  ) async {
    final service = _MemoryArrivalService()..add(1);
    final events = StreamController<PosLiveEvent>.broadcast();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DirectOrderArrivalAlertHost(
            enabledOverride: false,
            storeIdOverride: _storeId,
            service: service,
            liveEvents: events.stream,
            pollInterval: const Duration(milliseconds: 20),
            burstWindow: const Duration(milliseconds: 5),
            child: const Scaffold(body: Text('cashier')),
          ),
        ),
      ),
    );
    events.add(_event('*'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(service.fetches, 0);
    expect(
      find.byKey(const Key('direct_order_arrival_alert_banner')),
      findsNothing,
    );
    await events.close();
  });

  test(
    'new alert remains isolated to direct-only files and two route hosts',
    () {
      final router = File('lib/core/router/app_router.dart').readAsStringSync();
      expect(
        RegExp('DirectOrderArrivalAlertHost\\(').allMatches(router),
        hasLength(2),
      );
      for (final path in [
        'lib/features/direct_order/direct_order_arrival_alert_service.dart',
        'lib/features/direct_order/direct_order_arrival_alert_host.dart',
        'lib/features/direct_order/direct_order_arrival_alert_sound.dart',
        'lib/features/direct_order/direct_order_arrival_alert_sound_io.dart',
        'lib/features/direct_order/direct_order_arrival_alert_sound_web.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, isNot(contains('bank_transfer_alert')));
        expect(source, isNot(contains('sepay_push')));
        expect(source, isNot(contains('emergency_order_voice')));
        expect(source, isNot(contains('approve(')));
      }
    },
  );
}

Widget _localizedApp(String locale, Widget child) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<void> _pumpHost(
  WidgetTester tester, {
  required _MemoryArrivalService service,
  required _RecordingArrivalSound sound,
  required Stream<PosLiveEvent> events,
  required List<int> presented,
  VoidCallback? onView,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectOrderArrivalAlertHost(
          enabledOverride: true,
          storeIdOverride: _storeId,
          service: service,
          soundService: sound,
          liveEvents: events,
          pollInterval: const Duration(milliseconds: 40),
          burstWindow: const Duration(milliseconds: 20),
          onPresented: (count) {
            service.log.add('present');
            presented.add(count);
          },
          onViewOrders: onView,
          child: const Scaffold(body: Text('cashier')),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 5));
}

PosLiveEvent _event(String domain) => PosLiveEvent(
  domain: domain,
  sourceTable: 'direct_order_requests',
  eventType: 'INSERT',
  restaurantId: _storeId,
);

class _MemoryArrivalService extends DirectOrderArrivalAlertService {
  final Map<String, DirectOrderArrivalCursor> saved = {};
  final List<DirectOrderArrival> arrivals = [];
  final List<String> log = [];
  int fetches = 0;
  int failFetches = 0;
  int failSaves = 0;
  Completer<void>? baselineGate;

  void add(int sequence) {
    arrivals.add(
      DirectOrderArrival(
        requestId:
            'da000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
        createdAt: _time0.add(Duration(seconds: sequence)),
        state: 'awaiting_quote',
      ),
    );
  }

  @override
  Future<DirectOrderArrivalCursor?> loadCursor(String storeId) async =>
      saved[storeId];

  @override
  Future<void> saveCursor(
    String storeId,
    DirectOrderArrivalCursor cursor,
  ) async {
    if (failSaves > 0) {
      failSaves -= 1;
      throw StateError('storage');
    }
    saved[storeId] = cursor;
    log.add('save');
  }

  @override
  Future<DirectOrderArrivalBatch> fetchAfter(
    String storeId,
    DirectOrderArrivalCursor? cursor, {
    int limit = 100,
  }) async {
    fetches += 1;
    log.add('fetch');
    if (failFetches > 0) {
      failFetches -= 1;
      throw StateError('network');
    }
    if (cursor == null) {
      final gate = baselineGate;
      if (gate != null) {
        await gate.future;
        baselineGate = null;
      }
      final latest = arrivals.isEmpty
          ? _cursor0
          : DirectOrderArrivalCursor(
              createdAt: arrivals.last.createdAt,
              requestId: arrivals.last.requestId,
            );
      return DirectOrderArrivalBatch(
        items: const [],
        pendingCount: arrivals.length,
        nextCursor: latest,
        hasMore: false,
      );
    }
    final successors =
        arrivals.where((arrival) {
          final timeOrder = arrival.createdAt.compareTo(cursor.createdAt);
          return timeOrder > 0 ||
              (timeOrder == 0 &&
                  arrival.requestId.compareTo(cursor.requestId) > 0);
        }).toList()..sort((left, right) {
          final timeOrder = left.createdAt.compareTo(right.createdAt);
          return timeOrder != 0
              ? timeOrder
              : left.requestId.compareTo(right.requestId);
        });
    final page = successors.take(limit).toList(growable: false);
    final next = page.isEmpty
        ? cursor
        : DirectOrderArrivalCursor(
            createdAt: page.last.createdAt,
            requestId: page.last.requestId,
          );
    return DirectOrderArrivalBatch(
      items: page,
      pendingCount: arrivals
          .where((item) => item.state == 'awaiting_quote')
          .length,
      nextCursor: next,
      hasMore: successors.length > page.length,
    );
  }
}

class _RecordingArrivalSound extends DirectOrderArrivalAlertSoundService {
  int plays = 0;
  bool fail = false;

  @override
  Future<void> prepare() async {}

  @override
  Future<void> play() async {
    plays += 1;
    if (fail) throw StateError('autoplay');
  }
}
