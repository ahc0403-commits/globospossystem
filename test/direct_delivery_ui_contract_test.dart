import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_browser_location.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_localization.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';

void main() {
  test('direct delivery routes preserve least-privilege role separation', () {
    expect(canAccessRouteForRole('cashier', '/cashier/direct-orders'), isTrue);
    expect(canAccessRouteForRole('cashier', '/kitchen/direct-orders'), isFalse);
    expect(
      canAccessRouteForRole('cashier', '/direct-delivery/analytics'),
      isFalse,
    );
    expect(canAccessRouteForRole('kitchen', '/kitchen/direct-orders'), isTrue);
    expect(canAccessRouteForRole('kitchen', '/cashier/direct-orders'), isFalse);
    for (final role in ['admin', 'store_admin', 'brand_admin', 'super_admin']) {
      expect(canAccessRouteForRole(role, '/cashier/direct-orders'), isTrue);
      expect(canAccessRouteForRole(role, '/kitchen/direct-orders'), isTrue);
      expect(canAccessRouteForRole(role, '/direct-delivery/analytics'), isTrue);
      expect(canAccessRouteForRole(role, '/direct-delivery/settings'), isTrue);
    }
    expect(canAccessRouteForRole('waiter', '/cashier/direct-orders'), isFalse);
  });

  test('cached address round-trips all user-entered and verified fields', () {
    const address = DirectOrderAddress(
      customerName: 'Nguyen An',
      customerPhone: '+84901234567',
      formattedAddress: '123 Nguyen Hue, District 1',
      detailAddress: 'Floor 4, room 401',
      latitude: 10.775,
      longitude: 106.704,
      googlePlaceId: 'place-id',
      district: 'District 1',
      ward: 'Ben Nghe',
      addressSource: 'search',
      locationVerified: true,
    );

    final restored = DirectOrderAddress.decode(address.encode());
    expect(restored.customerName, address.customerName);
    expect(restored.customerPhone, address.customerPhone);
    expect(restored.formattedAddress, address.formattedAddress);
    expect(restored.detailAddress, address.detailAddress);
    expect(restored.latitude, address.latitude);
    expect(restored.longitude, address.longitude);
    expect(restored.locationVerified, isTrue);
  });

  test(
    'non-web location adapter fails safely without requesting permission',
    () async {
      final result = await directOrderBrowserLocationAdapter.currentPosition(
        timeout: const Duration(milliseconds: 1),
      );
      expect(result.isSuccess, isFalse);
      expect(result.failure, DirectOrderLocationFailure.unsupported);
    },
  );

  test('provider place coordinates are finite and in range', () {
    final valid = <String, dynamic>{
      'place_id': 'ChIJfixture',
      'formatted_address': 'Landmark 81, Ho Chi Minh City',
      'latitude': 10.795,
      'longitude': 106.722,
      'district': 'Binh Thanh',
      'ward': null,
    };
    expect(DirectOrderPlace.fromJson(valid).latitude, 10.795);
    expect(
      () => DirectOrderPlace.fromJson({...valid, 'latitude': 91}),
      throwsFormatException,
    );
    expect(
      () => DirectOrderPlace.fromJson({...valid, 'longitude': -181}),
      throwsFormatException,
    );
  });

  test(
    'cashier approval copy says kitchen handoff is manual in all locales',
    () {
      for (final language in ['ko', 'vi', 'en']) {
        final copy = DirectOrderCopy(language);
        expect(copy.manualApprovalCheck, isNotEmpty);
        expect(copy.approveAndSendKitchen, isNotEmpty);
        expect(copy.stateLabel('awaiting_payment_review'), copy.proofSubmitted);
      }
    },
  );

  test('customer and staff viewer locales stay independent in all 9 pairs', () {
    const names = {
      'ko': '한국어 메뉴',
      'vi': 'Món tiếng Việt',
      'en': 'English menu',
    };
    const menu = DirectOrderMenuItem(
      id: 'menu-id',
      categoryId: 'category-id',
      nameKo: '한국어 메뉴',
      nameVi: 'Món tiếng Việt',
      nameEn: 'English menu',
      description: null,
      price: 100000,
      imageUrl: null,
      vatCategory: 'food',
      sortOrder: 0,
    );
    final staffSnapshot = <String, dynamic>{
      'name_ko': names['ko'],
      'name_vi': names['vi'],
      'name_en': names['en'],
    };

    for (final customerLocale in directOrderLocales) {
      for (final staffLocale in directOrderLocales) {
        expect(
          menu.localizedName(customerLocale),
          names[customerLocale],
          reason: 'customer=$customerLocale staff=$staffLocale',
        );
        expect(
          localizedDirectOrderSnapshotName(staffSnapshot, staffLocale),
          names[staffLocale],
          reason: 'customer=$customerLocale staff=$staffLocale',
        );
      }
    }
  });

  test('system codes localize per viewer while free text remains exact', () {
    const expectedApproved = {
      'ko': '입금 확인 완료 · 조리를 시작합니다.',
      'vi': 'Đã xác nhận thanh toán · Bếp bắt đầu làm món.',
      'en': 'Payment confirmed · The kitchen is preparing your order.',
    };
    const freeText = 'Tầng 4, gọi tôi khi đến / 4층 도착 후 전화';
    for (final locale in directOrderLocales) {
      final copy = DirectOrderCopy(locale);
      expect(
        localizedDirectOrderMessage(
          copy: copy,
          messageType: 'system',
          body: 'DIRECT_ORDER_PAYMENT_APPROVED',
        ),
        expectedApproved[locale],
      );
      expect(
        localizedDirectOrderMessage(
          copy: copy,
          messageType: 'text',
          body: freeText,
        ),
        freeText,
      );
      expect(
        localizedDirectOrderMessage(
          copy: copy,
          messageType: 'system',
          body: freeText,
        ),
        freeText,
        reason: 'cashier rejection reason is not a fixed system code',
      );
      expect(copy.kitchenBoard, isNotEmpty);
      expect(copy.analytics, isNotEmpty);
      expect(copy.settings, isNotEmpty);
    }
  });

  test(
    'every direct viewer surface wires an always-visible language selector',
    () {
      for (final path in [
        'lib/features/direct_order/direct_order_storefront_screen.dart',
        'lib/features/direct_order/direct_order_cashier_screen.dart',
        'lib/features/direct_order/direct_order_kitchen_screen.dart',
        'lib/features/direct_order/direct_order_analytics_screen.dart',
        'lib/features/direct_order/direct_order_settings_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('LanguageSwitcher(compact: true)'),
          reason: path,
        );
      }
      for (final path in [
        'lib/features/direct_order/direct_order_cashier_screen.dart',
        'lib/features/direct_order/direct_order_kitchen_screen.dart',
        'lib/features/direct_order/direct_order_analytics_screen.dart',
        'lib/features/direct_order/direct_order_settings_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains('showLanguage: false'), reason: path);
      }
    },
  );

  test('new staff screens remain isolated from frozen POS providers', () {
    for (final path in [
      'lib/features/direct_order/direct_order_cashier_screen.dart',
      'lib/features/direct_order/direct_order_kitchen_screen.dart',
      'lib/features/direct_order/direct_order_analytics_screen.dart',
      'lib/features/direct_order/direct_order_settings_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('orderProvider')));
      expect(source, isNot(contains('paymentProvider')));
      expect(source, isNot(contains('kitchenProvider')));
      expect(source, contains('direct_order'));
    }
  });

  test('customer response models reject missing and uncontracted fields', () {
    final storefront = <String, dynamic>{
      'store_id': 'dd000000-0000-4000-8000-000000000001',
      'store_name': 'Contract Store',
      'slug': 'contract-store',
      'paused': false,
      'ordering_starts_at': '10:00:00',
      'ordering_cutoff_at': '21:30:00',
      'minimum_order_amount': 0,
      'default_latitude': 10.775,
      'default_longitude': 106.704,
      'google_maps_browser_key': null,
      'bank': {
        'bin': '970436',
        'account_number': '123456789',
        'account_holder': 'GLOBOS',
        'label': null,
      },
      'categories': <dynamic>[],
      'items': <dynamic>[],
    };
    expect(DirectOrderStorefront.fromJson(storefront).slug, 'contract-store');

    final missing = Map<String, dynamic>.from(storefront)..remove('store_id');
    expect(
      () => DirectOrderStorefront.fromJson(missing),
      throwsFormatException,
    );

    final unknown = Map<String, dynamic>.from(storefront)
      ..['unexpected_private_field'] = 'must not be accepted';
    expect(
      () => DirectOrderStorefront.fromJson(unknown),
      throwsFormatException,
    );

    final status = <String, dynamic>{
      'request_id': 'dd000000-0000-4000-8000-000000000002',
      'store_id': 'dd000000-0000-4000-8000-000000000001',
      'reference_code': 'D12345678',
      'state': 'awaiting_quote',
      'created_at': '2026-08-21T12:00:00Z',
      'items': <dynamic>[],
      'quote': null,
      'messages': <dynamic>[],
      'fulfillment': null,
      'dispatch': null,
    };
    expect(DirectOrderStatus.fromJson(status).state, 'awaiting_quote');
    final missingMessages = Map<String, dynamic>.from(status)
      ..remove('messages');
    expect(
      () => DirectOrderStatus.fromJson(missingMessages),
      throwsFormatException,
    );
  });

  test('every Edge public error code has KO VI EN copy and a safe fallback', () {
    final edge = File(
      'supabase/functions/direct-order-public/index.ts',
    ).readAsStringSync();
    final publicCodes = <String>{
      ...RegExp(
        r'(?:invalidRequest|forbidden|unavailable|conflict)\("([A-Z0-9_]+)"\)',
      ).allMatches(edge).map((match) => match.group(1)!),
      ...RegExp(
        r'(?:error|publicCode):\s*"([A-Z0-9_]+)"',
      ).allMatches(edge).map((match) => match.group(1)!),
      ...RegExp(
        r'new SafeHttpError\(\d+,\s*"([A-Z0-9_]+)"\)',
      ).allMatches(edge).map((match) => match.group(1)!),
    };
    expect(publicCodes, isNotEmpty);
    for (final language in const ['ko', 'vi', 'en']) {
      final copy = DirectOrderCopy(language);
      for (final code in publicCodes) {
        final message = copy.errorMessage(code);
        expect(message, isNotEmpty, reason: '$language:$code');
        expect(message, isNot(code), reason: '$language:$code leaked raw');
      }
      expect(copy.errorMessage('UNKNOWN_PRIVATE_ERROR'), copy.unavailable);
    }
  });
}
