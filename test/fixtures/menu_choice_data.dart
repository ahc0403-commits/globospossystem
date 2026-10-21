import 'dart:convert';

Map<String, dynamic> definition() => {
  'schema_version': 1,
  'groups': [
    {
      'id': 'spice',
      'name_ko': '맵기',
      'name_vi': 'Độ cay',
      'name_en': 'Spice',
      'min': 1,
      'max': 1,
      'repeat': false,
      'channels': ['pos', 'qr', 'direct'],
      'values': [
        {
          'id': 'mild',
          'name_ko': '안맵게',
          'name_vi': 'Không cay',
          'name_en': 'Mild',
          'price_delta': 0,
          'available': true,
          'default_quantity': 1,
        },
        {
          'id': 'hot',
          'name_ko': '맵게',
          'name_vi': 'Cay',
          'name_en': 'Hot',
          'price_delta': 2000,
          'available': true,
        },
        {
          'id': 'gone',
          'name_ko': '품절',
          'name_vi': 'Hết',
          'name_en': 'Sold out',
          'price_delta': 0,
          'available': false,
        },
      ],
    },
    {
      'id': 'salt',
      'name_ko': '짜기',
      'name_vi': 'Độ mặn',
      'name_en': 'Salt',
      'min': 1,
      'max': 1,
      'repeat': false,
      'channels': ['pos', 'qr', 'direct'],
      'values': [
        {
          'id': 'less',
          'name_ko': '덜 짜게',
          'name_vi': 'Ít mặn',
          'name_en': 'Less salt',
          'price_delta': 0,
          'available': true,
        },
        {
          'id': 'normal',
          'name_ko': '중간',
          'name_vi': 'Vừa',
          'name_en': 'Normal',
          'price_delta': 0,
          'available': true,
        },
      ],
    },
  ],
  'rules': [
    {'kind': 'excludes', 'from': 'hot', 'to': 'less'},
  ],
};
String catalogKey({String? legacy, double price = 10000}) => jsonEncode({
  'schema': 2,
  'base_price': price,
  'legacy_key': legacy,
  'definition': definition(),
  'definition_revision': 'fixture',
});
