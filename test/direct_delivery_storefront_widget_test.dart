import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_browser_location.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_map_view.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StorefrontFixtureService extends DirectOrderService {
  _StorefrontFixtureService({
    this.browserKey,
    this.savedAddress,
    this.activeStatus,
    this.autocompleteHandler,
  });

  final String? browserKey;
  final DirectOrderAddress? savedAddress;
  final DirectOrderStatus? activeStatus;
  final Future<List<DirectOrderPlaceSuggestion>> Function(
    String query,
    String sessionToken,
  )?
  autocompleteHandler;
  final autocompleteTokens = <String>[];
  final detailsTokens = <String>[];
  final reversePoints = <LatLng>[];
  var _tokenCounter = 0;
  var fetchStatusCalls = 0;
  var sendMessageCalls = 0;

  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async =>
      DirectOrderStorefront(
        storeId: 'fixture-store',
        storeName: 'GLOBOS BUNSIK',
        slug: 'fixture-store',
        paused: false,
        minimumOrderAmount: 100000,
        defaultLatitude: 10.8,
        defaultLongitude: 106.7,
        googleMapsBrowserKey: browserKey,
        bank: const DirectOrderBank(
          bin: '970436',
          accountNumber: '123456789',
          accountHolder: 'GLOBOS VN',
          label: 'Vietcombank',
        ),
        categories: const [
          DirectOrderCategory(
            id: 'popular',
            nameKo: '인기 메뉴',
            nameVi: 'Món phổ biến',
            nameEn: 'Popular',
            sortOrder: 1,
          ),
        ],
        items: const [
          DirectOrderMenuItem(
            id: 'tteokbokki',
            categoryId: 'popular',
            nameKo: '즉석 떡볶이',
            nameVi: 'Tokbokki cay',
            nameEn: 'Spicy tteokbokki',
            description: 'Bánh gạo, chả cá và sốt cay',
            price: 125000,
            imageUrl: null,
            vatCategory: 'food',
            sortOrder: 1,
          ),
        ],
      );

  @override
  Future<DirectOrderSession> ensureSession({
    required String slug,
    required String locale,
  }) async => DirectOrderSession(
    id: 'fixture-session',
    secret: 'fixture-secret',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  @override
  Future<DirectOrderAddress?> loadAddress(String slug) async => savedAddress;

  @override
  Future<String?> loadActiveRequestId(String slug) async =>
      activeStatus?.requestId;

  @override
  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async {
    fetchStatusCalls += 1;
    return activeStatus!;
  }

  @override
  Future<DirectOrderMessage> sendMessage({
    required DirectOrderSession session,
    required String requestId,
    required String message,
  }) async {
    sendMessageCalls += 1;
    return DirectOrderMessage(
      id: 'fixture-sent-message',
      senderType: 'customer',
      messageType: 'text',
      body: message,
      hasAttachment: false,
      createdAt: DateTime.utc(2026, 8, 24, 3),
    );
  }

  @override
  String createPlacesSessionToken() => 'test-session-${++_tokenCounter}';

  @override
  Future<List<DirectOrderPlaceSuggestion>> autocomplete({
    required String slug,
    required String query,
    required String locale,
    required String sessionToken,
  }) async {
    autocompleteTokens.add(sessionToken);
    return autocompleteHandler?.call(query, sessionToken) ??
        const [
          DirectOrderPlaceSuggestion(
            placeId: 'ChIJfixture',
            text: 'Landmark 81',
          ),
        ];
  }

  @override
  Future<DirectOrderPlace> placeDetails({
    required String placeId,
    required String locale,
    required String sessionToken,
  }) async {
    detailsTokens.add(sessionToken);
    return const DirectOrderPlace(
      formattedAddress: 'Landmark 81, Bình Thạnh, Hồ Chí Minh',
      latitude: 10.795,
      longitude: 106.722,
      placeId: 'ChIJfixture',
      district: 'Bình Thạnh',
      ward: 'Phường 22',
    );
  }

  @override
  Future<DirectOrderPlace> reverseGeocode({
    required double latitude,
    required double longitude,
    required String locale,
  }) async {
    reversePoints.add(LatLng(latitude, longitude));
    return DirectOrderPlace(
      formattedAddress: 'Vị trí hiện tại, Hồ Chí Minh',
      latitude: latitude,
      longitude: longitude,
      district: 'Quận 1',
      ward: 'Bến Nghé',
    );
  }
}

class _LocationFixture implements DirectOrderBrowserLocationAdapter {
  _LocationFixture(this.result);

  final DirectOrderBrowserLocationResult result;
  var calls = 0;

  @override
  Future<DirectOrderBrowserLocationResult> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    calls += 1;
    return result;
  }
}

class _FakeMapCamera implements DirectOrderMapCamera {
  final targets = <LatLng>[];
  var disposed = false;

  @override
  void dispose() => disposed = true;

  @override
  Future<void> moveTo(LatLng target) async => targets.add(target);
}

class _FakeMap extends StatefulWidget {
  const _FakeMap({required this.configuration, required this.camera});

  final DirectOrderMapConfiguration configuration;
  final DirectOrderMapCamera camera;

  @override
  State<_FakeMap> createState() => _FakeMapState();
}

class _FakeMapState extends State<_FakeMap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.configuration.onCameraReady(widget.camera);
    });
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.configuration.semanticLabel,
    child: GestureDetector(
      key: const Key('direct_fake_map'),
      onTap: () => widget.configuration.onTap(const LatLng(10.79, 106.71)),
      child: const ColoredBox(color: Colors.blueGrey),
    ),
  );
}

Widget _fixtureApp({
  _StorefrontFixtureService? service,
  DirectOrderBrowserLocationAdapter? locationAdapter,
  Future<bool> Function(String)? mapLoader,
  DirectOrderMapBuilder? mapBuilder,
  Locale locale = const Locale('vi'),
}) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.build(),
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: DirectOrderStorefrontScreen(
      slug: 'fixture-store',
      service: service ?? _StorefrontFixtureService(),
      locationAdapter: locationAdapter,
      mapLoader: mapLoader,
      mapBuilder: mapBuilder,
    ),
  ),
);

Future<void> _openAddress(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
  await tester.pump();
  await tester.tap(find.text('Địa chỉ').last);
  await tester.pumpAndSettle();
}

DirectOrderMapBuilder _fakeMapBuilder(_FakeMapCamera camera) =>
    (context, configuration) =>
        _FakeMap(configuration: configuration, camera: camera);

void main() {
  testWidgets('storefront stays usable at all required responsive widths', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final size in const [
      Size(390, 844),
      Size(768, 1024),
      Size(1024, 768),
      Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_fixtureApp());
      await tester.pumpAndSettle();
      expect(find.text('Tokbokki cay'), findsOneWidget, reason: '$size');
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('customer can open both address paths at every required size', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final size in const [
      Size(390, 844),
      Size(768, 1024),
      Size(1024, 768),
      Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_fixtureApp());
      await tester.pumpAndSettle();
      await _openAddress(tester);

      expect(
        find.byKey(const Key('direct_address_search')),
        findsOneWidget,
        reason: '$size',
      );
      expect(find.text('Chọn trực tiếp trên bản đồ'), findsOneWidget);
      expect(find.text('Lưu địa chỉ trên thiết bị này'), findsOneWidget);
      await tester.tap(find.text('Chọn trực tiếp trên bản đồ'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('direct_use_current_location')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'current location is requested only on tap then moves and resolves map',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final service = _StorefrontFixtureService(browserKey: 'browser-key');
      final location = _LocationFixture(
        const DirectOrderBrowserLocationResult.success(
          latitude: 10.781,
          longitude: 106.704,
          accuracyMeters: 12,
        ),
      );
      final camera = _FakeMapCamera();
      await tester.pumpWidget(
        _fixtureApp(
          service: service,
          locationAdapter: location,
          mapLoader: (_) async => true,
          mapBuilder: _fakeMapBuilder(camera),
        ),
      );
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      expect(location.calls, 0, reason: 'no automatic permission prompt');

      await _openAddress(tester);
      await tester.tap(find.text('Chọn trực tiếp trên bản đồ'));
      await tester.pumpAndSettle();
      expect(location.calls, 0);
      expect(
        find.bySemanticsLabel('Dùng vị trí hiện tại'),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.bySemanticsLabel('Bản đồ chọn vị trí giao hàng'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('direct_use_current_location')));
      await tester.pumpAndSettle();

      expect(location.calls, 1);
      expect(service.reversePoints, const [LatLng(10.781, 106.704)]);
      expect(camera.targets, const [LatLng(10.781, 106.704)]);
      expect(find.text('Vị trí hiện tại, Hồ Chí Minh'), findsOneWidget);
      expect(find.text('Đã xác nhận vị trí'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final entry in const {
    DirectOrderLocationFailure.permissionDenied: 'Quyền vị trí đã bị từ chối.',
    DirectOrderLocationFailure.timeout: 'Hết thời gian xác định vị trí.',
    DirectOrderLocationFailure.unavailable:
        'Không thể xác định vị trí hiện tại.',
    DirectOrderLocationFailure.unsupported:
        'Trình duyệt này không hỗ trợ vị trí hiện tại.',
  }.entries) {
    testWidgets(
      'current location ${entry.key.name} keeps manual pin fallback',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        final location = _LocationFixture(
          DirectOrderBrowserLocationResult.failure(entry.key),
        );
        final camera = _FakeMapCamera();
        await tester.pumpWidget(
          _fixtureApp(
            service: _StorefrontFixtureService(browserKey: 'browser-key'),
            locationAdapter: location,
            mapLoader: (_) async => true,
            mapBuilder: _fakeMapBuilder(camera),
          ),
        );
        await tester.pumpAndSettle();
        await _openAddress(tester);
        await tester.tap(find.text('Chọn trực tiếp trên bản đồ'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('direct_use_current_location')));
        await tester.pumpAndSettle();

        expect(location.calls, 1);
        expect(find.textContaining(entry.value), findsOneWidget);
        expect(
          find.textContaining('Vui lòng chọn vị trí trực tiếp trên bản đồ.'),
          findsOneWidget,
        );
        expect(camera.targets, const [LatLng(10.8, 106.7)]);
        expect(find.byKey(const Key('direct_fake_map')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Places session token pairs autocomplete and selected details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final service = _StorefrontFixtureService();
    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    await _openAddress(tester);

    await tester.enterText(
      find.byKey(const Key('direct_address_search')),
      'Landmark',
    );
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landmark 81'));
    await tester.pumpAndSettle();

    expect(service.autocompleteTokens, hasLength(1));
    expect(service.detailsTokens, service.autocompleteTokens);

    await tester.enterText(
      find.byKey(const Key('direct_address_search')),
      'Another building',
    );
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pumpAndSettle();
    expect(service.autocompleteTokens, hasLength(2));
    expect(service.autocompleteTokens[1], isNot(service.autocompleteTokens[0]));

    await tester.enterText(find.byKey(const Key('direct_address_search')), 'x');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('direct_address_search')),
      'Third building',
    );
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pumpAndSettle();
    expect(service.autocompleteTokens, hasLength(3));
    expect(service.autocompleteTokens[2], isNot(service.autocompleteTokens[1]));
  });

  testWidgets('stale autocomplete response cannot replace the latest query', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final first = Completer<List<DirectOrderPlaceSuggestion>>();
    final second = Completer<List<DirectOrderPlaceSuggestion>>();
    final service = _StorefrontFixtureService(
      autocompleteHandler: (query, _) =>
          query == 'First address' ? first.future : second.future,
    );
    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    await _openAddress(tester);
    final field = find.byKey(const Key('direct_address_search'));

    await tester.enterText(field, 'First address');
    await tester.pump(const Duration(milliseconds: 351));
    await tester.enterText(field, 'Second address');
    await tester.pump(const Duration(milliseconds: 351));
    first.complete(const [
      DirectOrderPlaceSuggestion(placeId: 'ChIJfirst', text: 'Old result'),
    ]);
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    second.complete(const [
      DirectOrderPlaceSuggestion(placeId: 'ChIJsecond', text: 'New result'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New result'), findsOneWidget);
  });

  testWidgets(
    'cached address bypasses every Google Maps request until changed',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      const saved = DirectOrderAddress(
        customerName: 'Nguyen Van A',
        customerPhone: '+84901234567',
        formattedAddress: 'Landmark 81, Bình Thạnh, Hồ Chí Minh',
        detailAddress: 'Tầng 12, căn 1201',
        latitude: 10.795,
        longitude: 106.722,
        addressSource: 'search',
        locationVerified: true,
      );
      final service = _StorefrontFixtureService(
        browserKey: 'browser-key',
        savedAddress: saved,
      );
      final camera = _FakeMapCamera();
      var mapLoadCalls = 0;
      await tester.pumpWidget(
        _fixtureApp(
          service: service,
          mapLoader: (_) async {
            mapLoadCalls += 1;
            return true;
          },
          mapBuilder: _fakeMapBuilder(camera),
        ),
      );
      await tester.pumpAndSettle();
      expect(mapLoadCalls, 0, reason: 'menu must not preload Google Maps');
      await _openAddress(tester);

      expect(mapLoadCalls, 0, reason: 'saved address must not load Maps JS');
      expect(find.text('Đã xác nhận vị trí'), findsOneWidget);
      expect(find.byKey(const Key('direct_address_search')), findsNothing);
      expect(find.byKey(const Key('direct_fake_map')), findsNothing);
      expect(service.autocompleteTokens, isEmpty);
      expect(service.detailsTokens, isEmpty);
      expect(service.reversePoints, isEmpty);

      await tester.tap(find.byKey(const Key('direct_change_saved_address')));
      await tester.pumpAndSettle();

      expect(mapLoadCalls, 1, reason: 'Maps loads only after address change');
      expect(find.byKey(const Key('direct_address_search')), findsOneWidget);
      expect(find.byKey(const Key('direct_fake_map')), findsOneWidget);
      expect(service.autocompleteTokens, isEmpty);
      expect(service.detailsTokens, isEmpty);
      expect(service.reversePoints, isEmpty);
    },
  );

  testWidgets('new customer loads Google Maps only after opening address', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    var mapLoadCalls = 0;
    await tester.pumpWidget(
      _fixtureApp(
        service: _StorefrontFixtureService(browserKey: 'browser-key'),
        mapLoader: (_) async {
          mapLoadCalls += 1;
          return true;
        },
        mapBuilder: _fakeMapBuilder(_FakeMapCamera()),
      ),
    );
    await tester.pumpAndSettle();

    expect(mapLoadCalls, 0);
    await _openAddress(tester);
    expect(mapLoadCalls, 1);
  });

  testWidgets('map load failure stays safe and keeps search fallback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    await tester.pumpWidget(
      _fixtureApp(
        service: _StorefrontFixtureService(browserKey: 'browser-key'),
        mapLoader: (_) async => false,
      ),
    );
    await tester.pumpAndSettle();
    await _openAddress(tester);
    expect(
      find.text('Không tải được bản đồ. Vui lòng dùng tìm kiếm địa chỉ.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Chọn trực tiếp trên bản đồ'));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('direct_use_current_location')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('direct_address_search')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent chat message renders without a second status round trip', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const status = DirectOrderStatus(
      requestId: 'fixture-request',
      referenceCode: 'D12345678',
      state: 'awaiting_quote',
      messages: [],
    );
    final service = _StorefrontFixtureService(activeStatus: status);

    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    expect(service.fetchStatusCalls, 1);

    await tester.enterText(
      find.widgetWithText(TextField, 'Nhập tin nhắn'),
      'Xin chào',
    );
    await tester.ensureVisible(find.byTooltip('Gửi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Gửi'));
    await tester.pumpAndSettle();

    expect(find.text('Xin chào'), findsOneWidget);
    expect(service.sendMessageCalls, 1);
    expect(
      service.fetchStatusCalls,
      1,
      reason: 'successful send is appended locally instead of refetching',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'customer sees the four-stage delivery progress in their locale',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      const status = DirectOrderStatus(
        requestId: 'fixture-request',
        referenceCode: 'D12345678',
        state: 'approved',
        fulfillmentStatus: 'preparing',
        messages: [],
      );

      await tester.pumpWidget(
        _fixtureApp(
          service: _StorefrontFixtureService(activeStatus: status),
          locale: const Locale('ko'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('direct_order_customer_progress')),
        findsOneWidget,
      );
      expect(find.text('주문 확인'), findsOneWidget);
      expect(find.text('입금 확인'), findsOneWidget);
      expect(find.text('메뉴 조리 중'), findsOneWidget);
      expect(find.text('Grab 기사 전달 완료'), findsOneWidget);
      final statusTitle = tester.widget<Text>(
        find.byKey(const Key('direct_order_status_title')),
      );
      expect(statusTitle.data, '조리 중');
      for (var index = 0; index < 4; index++) {
        expect(
          find.byKey(Key('direct_order_progress_step_$index')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
