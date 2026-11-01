import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_delivery_quality.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/menu_choice_data.dart' as choices;
import 'fixtures/direct_order_notice_capture.dart';

// Independent expected catalog scope, not derived from the implementation set.
const expectedMenuIds = [
  'b3520540-6722-4782-97e4-11debf7d63e5',
  'e4181065-c4c1-45d3-bdae-de0b31feed81',
  '8182aa51-628f-40dd-93c4-f60f1347157b',
  '98bedacb-4562-4c4a-80ba-08dce829af59',
  '11cbe616-15c2-494d-b94a-2842e15acfd2',
  '3cddfae1-c591-4986-a0ef-b9871a4ec315',
];
const expectedQualityText = {
  'ko': '음식의 특성상 배달 시간에 따라 맛과 식감이 달라질 수 있습니다.',
  'vi':
      'Hương vị và kết cấu món ăn có thể thay đổi tùy theo thời gian giao hàng.',
  'en': 'Taste and texture may vary depending on delivery time.',
};

DirectOrderMenuItem item(String id, {String? option, bool combo = false}) =>
    DirectOrderMenuItem(
      id: id,
      menuOptionKey: option,
      categoryId: 'fixture-category',
      nameKo: '이름 변경에도 같은 상품',
      nameVi: 'Tên món được đổi nhưng giữ nguyên mã',
      nameEn: 'Renamed dish with the same identity',
      description: 'Existing description stays unchanged',
      price: 45000,
      imageUrl: null,
      vatCategory: 'food',
      sortOrder: 0,
      isCombo: combo,
    );

class _MenuService extends DirectOrderService {
  _MenuService(this.menuItem, {this.storeId = deliveryQualityNoticeStoreId})
    : super(invoker: (_) async => throw StateError('Unexpected backend call'));
  final DirectOrderMenuItem menuItem;
  final String storeId;
  int catalogReads = 0;

  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async {
    catalogReads++;
    return DirectOrderStorefront(
      storeId: storeId,
      storeName: 'Fixture restaurant',
      slug: slug,
      paused: false,
      minimumOrderAmount: 0,
      defaultLatitude: null,
      defaultLongitude: null,
      googleMapsBrowserKey: null,
      bank: const DirectOrderBank(
        bin: '000000',
        accountNumber: 'fixture-account',
        accountHolder: 'SYNTHETIC ONLY',
        label: 'Fixture bank',
      ),
      categories: const [
        DirectOrderCategory(
          id: 'fixture-category',
          nameKo: '메뉴',
          nameVi: 'Món ăn',
          nameEn: 'Food',
          sortOrder: 0,
        ),
      ],
      items: [menuItem],
    );
  }

  @override
  Future<DirectOrderSession?> loadRestorableSession(String slug) async => null;
  @override
  Future<DirectOrderSession> ensureSession({
    required String slug,
    required String locale,
  }) async => DirectOrderSession(
    id: 'synthetic-session',
    secret: 'synthetic-only',
    expiresAt: DateTime.utc(2099),
  );
  @override
  Future<List<DirectOrderSummary>> listOrders({
    required DirectOrderSession session,
  }) async => [];
}

Widget _app(_MenuService service, String language, {double scale = 1}) =>
    ProviderScope(
      child: RepaintBoundary(
        key: noticeCaptureKey,
        child: MaterialApp(
          theme: AppTheme.build(),
          locale: Locale(language),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: DirectOrderStorefrontScreen(
            slug: 'synthetic-store',
            service: service,
            now: () => DateTime.utc(2026, 11, 1, 5),
          ),
        ),
      ),
    );

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byKey(const PageStorageKey('direct_menu_list')),
    const Offset(0, -100),
    maxIteration: 15,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadNoticeFont);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('policy retains exactly the independently verified product scope', () {
    expect(deliveryQualityNoticeMenuIds, unorderedEquals(expectedMenuIds));
  });

  for (final id in expectedMenuIds) {
    test('verified identity $id is delivery-only and store scoped', () {
      expect(
        showsDeliveryQualityNotice(
          storeId: deliveryQualityNoticeStoreId,
          item: item(id),
          pickup: false,
        ),
        isTrue,
      );
      for (final store in [
        null,
        'another-store',
        '3a268807-771f-4fd4-84fe-e1b0b00de40a',
      ]) {
        expect(
          showsDeliveryQualityNotice(
            storeId: store,
            item: item(id),
            pickup: false,
          ),
          isFalse,
        );
      }
      expect(
        showsDeliveryQualityNotice(
          storeId: deliveryQualityNoticeStoreId,
          item: item(id),
          pickup: true,
        ),
        isFalse,
      );
      expect(
        showsDeliveryQualityNotice(
          storeId: deliveryQualityNoticeStoreId,
          item: item(id, combo: true),
          pickup: false,
        ),
        isFalse,
      );
    });
  }

  test('unknown item and combo identities never inherit a name match', () {
    for (final id in [
      'unknown-menu',
      '2c6dfbf2-9501-4a67-ad71-abf75aa12771',
      'aa90e19d-4c11-4fde-bb97-e1c3c15fc016',
    ]) {
      expect(
        showsDeliveryQualityNotice(
          storeId: deliveryQualityNoticeStoreId,
          item: item(id),
          pickup: false,
        ),
        isFalse,
      );
    }
  });

  test('choice and size rows use the existing canonical catalog identity', () {
    final base = deliveryQualityNoticeMenuIds.first;
    expect(
      showsDeliveryQualityNotice(
        storeId: deliveryQualityNoticeStoreId,
        item: item('$base~choice'),
        pickup: false,
      ),
      isTrue,
    );
    final option = jsonEncode([
      'S',
      '',
      0,
      false,
      {
        'menu_id': base,
        'names': {'name_ko': '메뉴', 'name_vi': 'Món ăn', 'name_en': 'Food'},
      },
    ]);
    expect(
      showsDeliveryQualityNotice(
        storeId: deliveryQualityNoticeStoreId,
        item: item('size-row', option: option),
        pickup: false,
      ),
      isTrue,
    );
  });

  for (final language in ['ko', 'vi', 'en']) {
    test('quality copy matches the owner text in $language', () {
      expect(
        DirectOrderCopy(language).deliveryQualityNotice,
        expectedQualityText[language],
      );
    });
    for (final width in [390.0, 1440.0]) {
      for (final id in expectedMenuIds) {
        testWidgets(
          '$language menu $id at $width shows full notice below unchanged price',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final model = item(id);
            final service = _MenuService(model);
            await tester.pumpWidget(_app(service, language));
            await tester.pumpAndSettle();
            final notice = find.byKey(
              Key('direct_delivery_quality_${model.id}'),
            );
            await reveal(tester, notice);
            expect(
              find.text(DirectOrderCopy(language).deliveryQualityNotice),
              findsOneWidget,
            );
            final text = tester.widget<Text>(notice);
            expect(text.maxLines, isNull);
            expect(text.overflow, isNot(TextOverflow.ellipsis));
            expect(
              tester.renderObject<RenderParagraph>(notice).didExceedMaxLines,
              isFalse,
            );
            final card = find
                .ancestor(of: notice, matching: find.byType(Card))
                .first;
            final price = find.descendant(
              of: card,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Text && (widget.data ?? '').contains('45.000'),
              ),
            );
            expect(price, findsOneWidget);
            expect(
              tester.getBottomLeft(price).dy,
              lessThanOrEqualTo(tester.getTopLeft(notice).dy),
            );
            expect(
              tester.getRect(card).contains(tester.getRect(notice).bottomRight),
              isTrue,
            );
            expect(service.catalogReads, 1);
            expect(model.price, 45000);
            expect(model.description, 'Existing description stays unchanged');
            await captureNotice(
              tester,
              'menu_${id.substring(0, 8)}_${language}_${width.toInt()}',
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'pickup toggle removes notice and delivery restores it without refetch',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _MenuService(item(deliveryQualityNoticeMenuIds.first));
      await tester.pumpWidget(_app(service, 'en'));
      await tester.pumpAndSettle();
      final notice = find.text(
        const DirectOrderCopy('en').deliveryQualityNotice,
      );
      await reveal(tester, notice);
      final toggle = find.byKey(const Key('direct_fulfillment_type'));
      await reveal(tester, toggle);
      await tester.tap(
        find.descendant(
          of: toggle,
          matching: find.text(const DirectOrderCopy('en').pickup),
        ),
      );
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      await tester.tap(
        find.descendant(
          of: toggle,
          matching: find.text(const DirectOrderCopy('en').delivery),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, notice);
      expect(notice, findsOneWidget);
      expect(service.catalogReads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'registered choices show the note after options and retain selection',
    (tester) async {
      final model = item(
        expectedMenuIds.first,
        option: choices.catalogKey(price: 45000),
      );
      await tester.pumpWidget(_app(_MenuService(model), 'en'));
      await tester.pumpAndSettle();
      final add = find.byKey(Key('direct_add_${model.id}'));
      await reveal(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final note = find.descendant(
        of: dialog,
        matching: find.text(expectedQualityText['en']!),
      );
      await tester.ensureVisible(note);
      await tester.pumpAndSettle();
      expect(note, findsOneWidget);
      final lastOption = find.descendant(
        of: dialog,
        matching: find.text('Normal'),
      );
      expect(
        tester.getBottomLeft(lastOption).dy,
        lessThanOrEqualTo(tester.getTopLeft(note).dy),
      );
      expect(
        tester.renderObject<RenderParagraph>(note).didExceedMaxLines,
        isFalse,
      );
      await captureNotice(tester, 'registered_detail_en');
      await tester.ensureVisible(lastOption);
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: lastOption, matching: find.byType(ListTile)),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('menu_choice_confirm')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('menu_choice_confirm')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      final cart = find.byKey(const Key('direct_view_cart'));
      await tester.ensureVisible(cart);
      await tester.tap(cart);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct_cart_sheet')), findsOneWidget);
      expect(find.textContaining('Mild'), findsWidgets);
      expect(find.textContaining('Normal'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'another storefront never displays the note for a copied item ID',
    (tester) async {
      await tester.pumpWidget(
        _app(
          _MenuService(item(expectedMenuIds.first), storeId: 'another-store'),
          'en',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(const DirectOrderCopy('en').deliveryQualityNotice),
        findsNothing,
      );
      expect(find.text(item(expectedMenuIds.first).nameEn), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'sized catalog card keeps the complete note below option prices',
    (tester) async {
      final option = jsonEncode([
        'S',
        '',
        0,
        false,
        {
          'menu_id': expectedMenuIds.first,
          'names': {'name_ko': '메뉴', 'name_vi': 'Món ăn', 'name_en': 'Food'},
        },
      ]);
      await tester.pumpWidget(
        _app(_MenuService(item('sized-row', option: option)), 'vi'),
      );
      await tester.pumpAndSettle();
      final note = find.byKey(const Key('direct_delivery_quality_sized-row'));
      await reveal(tester, note);
      final card = find.ancestor(of: note, matching: find.byType(Card)).first;
      final price = find.descendant(
        of: card,
        matching: find.textContaining('45.000'),
      );
      expect(price, findsOneWidget);
      expect(
        tester.getBottomLeft(price).dy,
        lessThanOrEqualTo(tester.getTopLeft(note).dy),
      );
      expect(tester.widget<Text>(note).maxLines, isNull);
      expect(
        tester.renderObject<RenderParagraph>(note).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(Key('direct_add_option_${expectedMenuIds.first}')),
      );
      await tester.pumpAndSettle();
      final picker = find.byKey(const Key('menu_size_picker'));
      final detailNotice = find.descendant(
        of: picker,
        matching: find.byKey(const Key('direct_delivery_quality_sized-row')),
      );
      await tester.ensureVisible(detailNotice);
      await tester.pumpAndSettle();
      expect(detailNotice, findsOneWidget);
      final sizeButton = find.byKey(const Key('menu_size_S'));
      expect(
        tester.getBottomLeft(sizeButton).dy,
        lessThanOrEqualTo(tester.getTopLeft(detailNotice).dy),
      );
      expect(
        tester.renderObject<RenderParagraph>(detailNotice).didExceedMaxLines,
        isFalse,
      );
      await captureNotice(tester, 'size_detail_vi');
      await tester.tap(sizeButton);
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Vietnamese notice remains within its card at 1.3 text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(_MenuService(item(expectedMenuIds.first)), 'vi', scale: 1.3),
    );
    await tester.pumpAndSettle();
    final note = find.text(const DirectOrderCopy('vi').deliveryQualityNotice);
    await reveal(tester, note);
    final card = find.ancestor(of: note, matching: find.byType(Card)).first;
    expect(
      tester.renderObject<RenderParagraph>(note).didExceedMaxLines,
      isFalse,
    );
    expect(
      tester.getRect(card).contains(tester.getRect(note).bottomRight),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await captureNotice(tester, 'menu_vi_scaled');
    await tester.pumpWidget(const SizedBox());
  });
}
