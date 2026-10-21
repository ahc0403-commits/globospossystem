import 'package:flutter/material.dart';

Map<String, dynamic> defaultStoreRegistrationConfig() => {
  'dine_in': true,
  'kitchens': 1,
  'tray': false,
  'tablet': false,
  'customer_display': false,
  'fulfillment_mode': 'paperless',
  'areas': [
    {'code': 'HALL', 'name': 'Hall', 'physical_floor': null},
  ],
};

String registrationText(BuildContext context, String key) {
  final index = switch (Localizations.localeOf(context).languageCode) {
    'ko' => 0,
    'vi' => 1,
    _ => 2,
  };
  return _labels[key]![index];
}

const _labels = <String, List<String>>{
  'automaticCode': [
    '비워 두면 매장 코드와 계정 ID를 자동 생성합니다.',
    'Để trống để tự tạo mã cửa hàng và tài khoản.',
    'Leave blank to generate the store code and account IDs.',
  ],
  'areas': ['서비스 구역', 'Khu vực phục vụ', 'Service areas'],
  'dineIn': ['매장 내 식사', 'Ăn tại chỗ', 'Dine-in'],
  'noDineIn': [
    '포장·배달 전용: 홀과 테이블 계정을 만들지 않습니다.',
    'Chỉ mang đi/giao hàng: không tạo khu vực hoặc tài khoản phục vụ bàn.',
    'Pickup/delivery only: no hall or table-service accounts.',
  ],
  'receiver': ['인계 담당 계정', 'Tài khoản nhận phục vụ', 'Receiving account'],
  'sharedReceiver': [
    '여러 구역에 같은 담당 계정을 지정할 수 있습니다.',
    'Có thể dùng cùng tài khoản cho nhiều khu vực.',
    'Several areas can share one receiving account.',
  ],
  'areaName': ['구역 이름', 'Tên khu vực', 'Area name'],
  'physicalFloor': [
    '실제 층 (선택)',
    'Tầng thực tế (tùy chọn)',
    'Physical floor (optional)',
  ],
  'singleFloor': [
    '단층은 층을 입력하지 않아도 됩니다.',
    'Không cần nhập tầng cho cửa hàng một tầng.',
    'A single-floor store does not need a floor number.',
  ],
  'addArea': ['구역 추가', 'Thêm khu vực', 'Add area'],
  'kitchens': ['주방 수', 'Số bếp', 'Kitchens'],
  'tray': [
    '트레이 인계 담당 사용',
    'Có trạm trung chuyển',
    'Use a tray handoff station',
  ],
  'tablet': [
    '별도 주문 태블릿',
    'Máy tính bảng đặt món riêng',
    'Separate ordering tablet',
  ],
  'customerDisplay': ['고객용 화면', 'Màn hình khách hàng', 'Customer display'],
  'printing': [
    '주방·홀 출력 사용',
    'In phiếu bếp/khu vực',
    'Print kitchen/area tickets',
  ],
};

class StoreRegistrationConfigEditor extends StatelessWidget {
  const StoreRegistrationConfigEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;

  void _set(String key, dynamic next) => onChanged({...value, key: next});

  @override
  Widget build(BuildContext context) {
    final areas = (value['areas'] as List)
        .map((a) => Map<String, dynamic>.from(a as Map))
        .toList();
    final dineIn = value['dine_in'] == true;
    void editArea(int index, String key, String? text) {
      areas[index] = {...areas[index], key: text};
      _set('areas', areas);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('registration_dine_in'),
          contentPadding: EdgeInsets.zero,
          title: Text(registrationText(context, 'dineIn')),
          value: dineIn,
          onChanged: enabled
              ? (v) => onChanged({
                  ...value,
                  'dine_in': v,
                  'areas': v
                      ? defaultStoreRegistrationConfig()['areas']
                      : <dynamic>[],
                })
              : null,
        ),
        Text(registrationText(context, dineIn ? 'singleFloor' : 'noDineIn')),
        if (dineIn) ...[
          Text(registrationText(context, 'sharedReceiver')),
          for (var i = 0; i < areas.length; i++) ...[
            Row(
              key: ValueKey('area_${areas[i]['code']}'),
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: areas[i]['name']?.toString(),
                    enabled: enabled,
                    maxLength: 80,
                    decoration: InputDecoration(
                      labelText: registrationText(context, 'areaName'),
                    ),
                    validator: (v) => (v ?? '').trim().isEmpty
                        ? registrationText(context, 'areaName')
                        : null,
                    onChanged: (v) => editArea(i, 'name', v.trim()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: areas[i]['physical_floor']?.toString(),
                    enabled: enabled,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: registrationText(context, 'physicalFloor'),
                    ),
                    onChanged: (v) => editArea(
                      i,
                      'physical_floor',
                      v.trim().isEmpty ? null : v.trim(),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: enabled && areas.length > 1
                      ? () {
                          areas.removeAt(i);
                          _set('areas', areas);
                        }
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('area_receiver_${areas[i]['code']}'),
              initialValue: (areas[i]['receiver'] ?? areas[i]['code'])
                  .toString(),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: registrationText(context, 'receiver'),
              ),
              items: [
                for (final code in {
                  for (final area in areas)
                    (area['receiver'] ?? area['code']).toString(),
                  areas[i]['code'].toString(),
                })
                  DropdownMenuItem(value: code, child: Text(code)),
              ],
              onChanged: enabled ? (v) => editArea(i, 'receiver', v) : null,
            ),
          ],
          TextButton.icon(
            key: const Key('registration_add_area'),
            onPressed: enabled && areas.length < 16
                ? () {
                    var n = 1;
                    while (areas.any((a) => a['code'] == 'AREA$n')) {
                      n++;
                    }
                    _set('areas', [
                      ...areas,
                      {
                        'code': 'AREA$n',
                        'name': 'Area $n',
                        'physical_floor': null,
                      },
                    ]);
                  }
                : null,
            icon: const Icon(Icons.add),
            label: Text(registrationText(context, 'addArea')),
          ),
        ],
        DropdownButtonFormField<int>(
          key: const Key('registration_kitchens'),
          initialValue: value['kitchens'] as int,
          decoration: InputDecoration(
            labelText: registrationText(context, 'kitchens'),
          ),
          items: [
            for (var n = 1; n <= 8; n++)
              DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: enabled ? (n) => _set('kitchens', n) : null,
        ),
        for (final entry in {
          'tray': 'tray',
          'tablet': 'tablet',
          'customer_display': 'customerDisplay',
        }.entries)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(registrationText(context, entry.value)),
            value: value[entry.key] == true,
            onChanged: enabled ? (v) => _set(entry.key, v) : null,
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(registrationText(context, 'printing')),
          value: value['fulfillment_mode'] == 'pos_print',
          onChanged: enabled
              ? (v) => _set('fulfillment_mode', v ? 'pos_print' : 'paperless')
              : null,
        ),
      ],
    );
  }
}
