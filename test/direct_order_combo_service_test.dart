import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _page(String id, {bool next = false}) => {
  'store_id': 'shop',
  'store_name': 'Fixture',
  'store_address': 'Fixture Street',
  'slug': 'fixture',
  'paused': false,
  'minimum_order_amount': 0,
  'ordering_starts_at': '09:00:00',
  'ordering_cutoff_at': '21:30:00',
  'default_latitude': null,
  'default_longitude': null,
  'google_maps_browser_key': null,
  'bank': {
    'bin': '970436',
    'account_number': '123456789',
    'account_holder': 'FIXTURE ONLY',
    'label': 'Fixture',
  },
  'categories': [],
  'items': [
    {
      'id': id,
      'menu_option_key': '["L","spicy","",100000]',
      'category_id': 'combos',
      'name_ko': '콤보',
      'name_vi': 'Combo',
      'name_en': 'Combo',
      'description': null,
      'price': 100000,
      'image_url': null,
      'vat_category': 'food',
      'sort_order': 0,
      'is_combo': true,
      'combo_drink_choice_count': 1,
      'combo_components': [],
    },
  ],
  'combo_drink_options': [
    {
      'menu_item_id': 'drink',
      'name_ko': '음료',
      'name_vi': 'Đồ uống',
      'name_en': 'Drink',
      'quantity': 1,
    },
  ],
  'next_cursor': next ? {'sort_order': 0, 'id': id} : null,
};

void main() {
  test(
    'menu paging hydrates shared combo options without per-menu calls',
    () async {
      var calls = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          expect(body['action'], 'storefront_v3');
          expect(body['limit'], 200);
          calls++;
          if (calls == 1) return _page('first', next: true);
          expect(body['cursor'], {'sort_order': 0, 'id': 'first'});
          return _page('second');
        },
      );
      final menu = await service.fetchStorefront('fixture');
      expect(calls, 2);
      expect(menu.items, hasLength(2));
      expect(menu.items.first.menuOptionKey, '["L","spicy","",100000]');
      expect(
        menu.items.every(
          (item) => item.comboDrinkOptions.single.menuItemId == 'drink',
        ),
        isTrue,
      );
    },
  );
  test(
    'repeated menu cursor stops rather than fetching indefinitely',
    () async {
      var calls = 0;
      final service = DirectOrderService(
        invoker: (_) async {
          calls++;
          return _page('same', next: true);
        },
      );
      await expectLater(
        service.fetchStorefront('fixture'),
        throwsA(isA<DirectOrderException>()),
      );
      expect(calls, 2);
    },
  );
  test(
    'lost combo submission response preserves selected drinks and retry key',
    () async {
      SharedPreferences.setMockInitialValues({});
      final payloads = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          payloads.add(body);
          if (payloads.length == 1) {
            throw const DirectOrderException(
              'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
            );
          }
          return {
            'request_id': 'request',
            'reference_code': 'DFIXTURE',
            'state': 'awaiting_quote',
            'idempotent': true,
          };
        },
      );
      Future<DirectOrderSubmission> submit() => service.submit(
        slug: 'fixture',
        session: DirectOrderSession(
          id: 'session',
          secret: 'fixture',
          expiresAt: DateTime.utc(2099),
        ),
        locale: 'ko',
        cart: {'combo': 2},
        itemNotes: {},
        menuOptionKeys: {'combo': '["L","spicy","",100000]'},
        comboDrinkChoices: {
          'combo': ['cola', 'tea'],
        },
        address: const DirectOrderAddress(
          customerName: 'Fixture',
          customerPhone: '0901234567',
          formattedAddress: 'Fixture Street',
          detailAddress: '',
        ),
        rememberAddress: false,
        dinerCount: 2,
      );
      await expectLater(submit(), throwsA(isA<DirectOrderException>()));
      await submit();
      expect(
        payloads[0]['client_request_id'],
        payloads[1]['client_request_id'],
      );
      expect(payloads[0]['payload'], payloads[1]['payload']);
      expect(
        ((payloads[1]['payload'] as Map)['items'] as List)
            .single['menu_option_key'],
        '["L","spicy","",100000]',
      );
      expect(
        ((payloads[1]['payload'] as Map)['items'] as List)
            .single['combo_drink_choices'],
        ['cola', 'tea'],
      );
    },
  );
}
