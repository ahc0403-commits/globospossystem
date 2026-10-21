import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import 'workflow_service.dart';

class WorkflowSetupCard extends StatefulWidget {
  const WorkflowSetupCard({super.key, required this.storeId, this.service});
  final String storeId;
  final WorkflowService? service;
  @override
  State<WorkflowSetupCard> createState() => _WorkflowSetupCardState();
}

class _WorkflowSetupCardState extends State<WorkflowSetupCard> {
  Map<String, dynamic>? config;
  Map<String, dynamic>? draft;
  bool busy = false;
  bool dirty = false;
  String? error;
  int generation = 0;
  String tr(String ko, String vi, String en) =>
      workflowText(Localizations.localeOf(context).languageCode, ko, vi, en);
  List<Map<String, dynamic>> get stations =>
      (draft?['stations'] as List? ?? []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get routes =>
      (draft?['routes'] as List? ?? []).cast<Map<String, dynamic>>();
  @override
  void didUpdateWidget(WorkflowSetupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId) {
      generation++;
      config = draft = null;
      error = null;
      dirty = busy = false;
    }
  }

  Future<void> run(String action, {Map<String, dynamic>? device}) async {
    if (busy) return;
    final epoch = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await (widget.service ?? WorkflowService()).admin(
        widget.storeId,
        action: action,
        revision: (config?['revision'] as num?)?.toInt(),
        definition: action == 'save' ? draft : device,
      );
      if (!mounted || epoch != generation) return;
      final definition = next['draft'];
      setState(() {
        config = next;
        if (action == 'load' || action == 'save' || draft == null) {
          draft = definition is Map
              ? Map<String, dynamic>.from(
                  jsonDecode(jsonEncode(definition)) as Map,
                )
              : initial(next);
          dirty = false;
        }
      });
    } on PostgrestException catch (e) {
      if (!mounted || epoch != generation) return;
      setState(
        () => error = switch (e.message) {
          'WORKFLOW_CHANGED' => tr(
            '다른 관리자가 변경했습니다. 새로 조회하세요.',
            'Quản trị viên khác đã sửa. Tải lại.',
            'Another administrator changed the setup. Reload.',
          ),
          'WORKFLOW_DRAIN_REQUIRED' => tr(
            '열린 주문·직접 주문·미완료 인계·포장을 먼저 마무리하세요.',
            'Hoàn tất đơn mở, giao nhận và đóng gói trước.',
            'Finish open orders, handoffs and packaging first.',
          ),
          'WORKFLOW_DEVICES_NOT_READY' => tr(
            '모든 담당 장치에서 게시 설정을 확인하고 미전송 요청을 동기화하세요. 확인은 5분간 유효합니다.',
            'Xác nhận cấu hình và đồng bộ yêu cầu trên mọi thiết bị. Xác nhận có hiệu lực 5 phút.',
            'Confirm the published setup and sync pending actions on every assigned device. Checks last 5 minutes.',
          ),
          'WORKFLOW_DEVICE_NOT_RETIRABLE' => tr(
            '미전송 0건이고 5분 이상 연결되지 않은 장치만 등록 해제할 수 있습니다.',
            'Chỉ gỡ thiết bị không có yêu cầu chờ và ngắt kết nối hơn 5 phút.',
            'Only devices with no pending actions and offline for over 5 minutes can be removed.',
          ),
          'WORKFLOW_REVALIDATE' => tr(
            '설정 또는 메뉴가 변경되었습니다. 검증부터 다시 진행하세요.',
            'Cấu hình hoặc thực đơn đã thay đổi. Kiểm tra lại.',
            'Setup or menu changed. Validate again.',
          ),
          'WORKFLOW_PAPERLESS_REQUIRED' => tr(
            '다중 주방은 화면 운영 모드에서 사용할 수 있습니다.',
            'Nhiều bếp cần chế độ màn hình.',
            'Multiple kitchens require paperless operation.',
          ),
          'WORKFLOW_SUPER_ADMIN_REQUIRED' => tr(
            '전환·복귀는 최고 관리자만 할 수 있습니다.',
            'Chỉ quản trị viên cấp cao được chuyển đổi.',
            'Activation and rollback require a super administrator.',
          ),
          _ =>
            e.code == 'PGRST202'
                ? tr(
                    '서버 업데이트 후 사용할 수 있습니다.',
                    'Có sau khi cập nhật máy chủ.',
                    'Available after the server update.',
                  )
                : tr(
                    '저장하지 못했습니다. 담당 배정·중복 경로·선택값을 확인하세요.',
                    'Không thể lưu. Kiểm tra phân công và tuyến trùng.',
                    'Could not save. Check assignments and duplicate routes.',
                  ),
        },
      );
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(
          () => error = tr(
            '불러오기 실패. 다시 시도하세요.',
            'Không thể tải. Thử lại.',
            'Could not load. Retry.',
          ),
        );
      }
    } finally {
      if (mounted && epoch == generation) setState(() => busy = false);
    }
  }

  Future<void> retireDevice(Map<String, dynamic> device) async {
    final store = widget.storeId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          tr(
            '오프라인 장치 등록 해제',
            'Gỡ thiết bị ngoại tuyến',
            'Remove offline device',
          ),
        ),
        content: Text(
          tr(
            '사용을 중단한 장치의 미전송 작업이 없음을 확인한 뒤 해제하세요. 기존 작업과 감사 이력은 유지되며, 전환하려면 담당 계정의 새 장치 확인이 필요합니다.',
            'Xác nhận thiết bị ngừng dùng không còn yêu cầu chờ. Lịch sử vẫn giữ; thiết bị thay thế phải xác nhận trước khi chuyển.',
            'Confirm the retired device has no pending actions. History is retained; the assigned account must confirm its replacement device before switching.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('취소', 'Hủy', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('등록 해제', 'Gỡ thiết bị', 'Remove device')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && widget.storeId == store) {
      await run(
        'retire_device',
        device: {
          'user_id': device['user_id'],
          'device_id': device['device_id'],
        },
      );
    }
  }

  Map<String, dynamic> initial(Map<String, dynamic> next) {
    final id = const Uuid().v4();
    return {
      'schema': 1,
      'workflow': next['current_workflow'],
      'fulfillment_mode': next['fulfillment_mode'],
      'stations': <Map<String, dynamic>>[
        {
          'id': id,
          'name': tr('주방 1', 'Bếp 1', 'Kitchen 1'),
          'user_ids': [
            for (final a in next['accounts'] as List? ?? [])
              if (a['kind'] == 'kitchen') a['id'],
          ],
        },
      ],
      'default_path': [id],
      'routes': <Map<String, dynamic>>[],
    };
  }

  void change(VoidCallback callback) => setState(() {
    callback();
    dirty = true;
  });
  Widget pathEditor(List<dynamic> path) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < path.length; i++)
        Row(
          children: [
            Text('${i + 1}. '),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: stations.any((s) => s['id'] == path[i])
                    ? path[i] as String
                    : null,
                items: [
                  for (final s in stations)
                    DropdownMenuItem(
                      value: s['id'] as String,
                      enabled: !path.contains(s['id']) || path[i] == s['id'],
                      child: Text(s['name'] as String),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) change(() => path[i] = value);
                      },
              ),
            ),
            IconButton(
              tooltip: tr('단계 삭제', 'Xóa bước', 'Remove step'),
              onPressed: busy || path.length <= 1
                  ? null
                  : () => change(() => path.removeAt(i)),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      TextButton(
        onPressed: busy || path.length >= stations.length
            ? null
            : () => change(
                () => path.add(
                  stations.firstWhere((s) => !path.contains(s['id']))['id'],
                ),
              ),
        child: Text(tr('다음 주방 추가', 'Thêm bếp tiếp theo', 'Add next kitchen')),
      ),
    ],
  );
  Future<void> addRoute() async {
    final menu = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _WorkflowMenuSearch(storeId: widget.storeId),
    );
    if (!mounted || menu == null) return;
    change(
      () => routes.add({
        'menu_ids': [menu['id']],
        'channels': ['dine_in', 'pickup', 'delivery'],
        'path': List.of(draft!['default_path'] as List),
        'label': menu['name'],
      }),
    );
  }

  Future<void> switchLive(String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          action == 'activate'
              ? tr(
                  '게시 설정으로 전환',
                  'Áp dụng cấu hình đã phát hành',
                  'Activate published setup',
                )
              : tr(
                  '기존 운영 방식으로 복귀',
                  'Trở về vận hành trước',
                  'Return to legacy operation',
                ),
        ),
        content: Text(
          tr(
            '주문과 인계가 모두 끝나고 모든 장치가 동기화된 경우에만 전환됩니다. 기존 주문 기록은 유지됩니다.',
            'Chỉ chuyển khi mọi đơn và bàn giao đã xong, mọi thiết bị đã đồng bộ. Giữ nguyên lịch sử đơn.',
            'The switch requires drained orders and handoffs and synchronized devices. Order history is retained.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await run(action);
  }

  @override
  Widget build(BuildContext context) {
    final accounts = (config?['accounts'] as List? ?? []).cast<Map>();
    return Card(
      key: const Key('workflow_setup_card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                '주방 경로·설정 게시',
                'Tuyến bếp và phát hành cấu hình',
                'Kitchen routes and publication',
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              tr(
                '주방을 순서대로 연결하거나 메뉴·채널별로 다른 주방을 지정합니다. 마지막 주방 이후에는 현재 트레이·층 배정을 사용합니다.',
                'Nối các bếp theo thứ tự hoặc chọn bếp theo món và kênh. Sau bếp cuối, giữ phân công khay và tầng hiện tại.',
                'Connect kitchens in sequence or route menus and channels to different kitchens. The final kitchen uses the current tray and floor assignments.',
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            OutlinedButton(
              onPressed: busy ? null : () => run('load'),
              child: Text(tr('설정 조회', 'Tải cấu hình', 'Load setup')),
            ),
            if (config != null && draft != null) ...[
              Text(
                config!['active_id'] == null
                    ? tr(
                        '현재: 기존 운영',
                        'Hiện tại: vận hành cũ',
                        'Current: legacy operation',
                      )
                    : tr(
                        '현재: 게시된 주방 경로',
                        'Hiện tại: tuyến bếp đã phát hành',
                        'Current: published kitchen routes',
                      ),
              ),
              if ((config!['releases'] as List? ?? []).isNotEmpty)
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    labelText: tr(
                      '이전 게시 설정을 초안으로 복원',
                      'Khôi phục bản phát hành vào nháp',
                      'Restore a previous release into the draft',
                    ),
                  ),
                  items: [
                    for (final release in config!['releases'] as List)
                      DropdownMenuItem(
                        value: release['id'] as String,
                        child: Text('${release['created_at']}'),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (id) {
                          if (id == null) return;
                          final release = (config!['releases'] as List)
                              .cast<Map>()
                              .firstWhere((r) => r['id'] == id);
                          change(
                            () => draft = Map<String, dynamic>.from(
                              jsonDecode(jsonEncode(release['definition']))
                                  as Map,
                            ),
                          );
                        },
                ),
              for (final station in stations)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        TextFormField(
                          key: ValueKey(station['id']),
                          initialValue: station['name'] as String,
                          maxLength: 80,
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: tr('주방 이름', 'Tên bếp', 'Kitchen name'),
                          ),
                          onChanged: (value) =>
                              change(() => station['name'] = value),
                        ),
                        Wrap(
                          children: [
                            for (final account in accounts.where(
                              (a) => a['kind'] == 'kitchen',
                            ))
                              FilterChip(
                                label: Text('${account['name']}'),
                                selected: (station['user_ids'] as List)
                                    .contains(account['id']),
                                onSelected: busy
                                    ? null
                                    : (selected) => change(() {
                                        for (final s in stations) {
                                          (s['user_ids'] as List).remove(
                                            account['id'],
                                          );
                                        }
                                        if (selected) {
                                          (station['user_ids'] as List).add(
                                            account['id'],
                                          );
                                        }
                                      }),
                              ),
                          ],
                        ),
                        TextButton(
                          onPressed: busy || stations.length <= 1
                              ? null
                              : () => change(() {
                                  stations.remove(station);
                                  (draft!['default_path'] as List).remove(
                                    station['id'],
                                  );
                                  for (final r in routes) {
                                    (r['path'] as List).remove(station['id']);
                                  }
                                }),
                          child: Text(tr('주방 제거', 'Xóa bếp', 'Remove kitchen')),
                        ),
                      ],
                    ),
                  ),
                ),
              TextButton(
                onPressed: busy || stations.length >= 8
                    ? null
                    : () => change(
                        () => stations.add({
                          'id': const Uuid().v4(),
                          'name': tr('새 주방', 'Bếp mới', 'New kitchen'),
                          'user_ids': <String>[],
                        }),
                      ),
                child: Text(tr('주방 추가', 'Thêm bếp', 'Add kitchen')),
              ),
              Text(tr('기본 경로', 'Tuyến mặc định', 'Default route')),
              pathEditor(draft!['default_path'] as List),
              for (final route in routes)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${route['label'] ?? route['menu_ids']}'),
                        Wrap(
                          children: [
                            for (final channel in [
                              'dine_in',
                              'pickup',
                              'delivery',
                            ])
                              FilterChip(
                                label: Text(switch (channel) {
                                  'dine_in' => tr('매장', 'Tại bàn', 'Dine in'),
                                  'pickup' => tr('픽업', 'Mang đi', 'Pickup'),
                                  _ => tr('배달', 'Giao hàng', 'Delivery'),
                                }),
                                selected: (route['channels'] as List).contains(
                                  channel,
                                ),
                                onSelected: busy
                                    ? null
                                    : (selected) => change(() {
                                        if (selected) {
                                          (route['channels'] as List).add(
                                            channel,
                                          );
                                        } else {
                                          (route['channels'] as List).remove(
                                            channel,
                                          );
                                        }
                                      }),
                              ),
                          ],
                        ),
                        pathEditor(route['path'] as List),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => change(() => routes.remove(route)),
                          child: Text(
                            tr(
                              '예외 경로 삭제',
                              'Xóa tuyến riêng',
                              'Remove route override',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              TextButton(
                onPressed: busy || routes.length >= 100 ? null : addRoute,
                child: Text(
                  tr('메뉴별 경로 추가', 'Thêm tuyến theo món', 'Add menu route'),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy ? null : () => run('save'),
                    child: Text(tr('초안 저장', 'Lưu bản nháp', 'Save draft')),
                  ),
                  OutlinedButton(
                    onPressed: busy || dirty || config!['draft'] == null
                        ? null
                        : () => run('validate'),
                    child: Text(
                      tr(
                        '경로 검증·모의 실행',
                        'Kiểm tra và mô phỏng',
                        'Validate and simulate',
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed:
                        busy || dirty || config!['validated_hash'] == null
                        ? null
                        : () => run('publish'),
                    child: Text(
                      tr(
                        '검증 설정 게시',
                        'Phát hành cấu hình',
                        'Publish validated setup',
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: busy || dirty || config!['candidate_id'] == null
                        ? null
                        : () => switchLive('activate'),
                    child: Text(
                      tr(
                        '장치 확인 후 전환',
                        'Kích hoạt sau xác nhận',
                        'Activate after device checks',
                      ),
                    ),
                  ),
                  if (config!['active_id'] != null)
                    OutlinedButton(
                      onPressed: busy ? null : () => switchLive('deactivate'),
                      child: Text(
                        tr(
                          '기존 운영으로 복귀',
                          'Trở về vận hành cũ',
                          'Return to legacy operation',
                        ),
                      ),
                    ),
                ],
              ),
              if (config!['proof'] is Map)
                Text(
                  tr(
                    '검증된 메뉴 ${(config!['proof'] as Map)['menu_count']}개 · 채널 경로 ${(config!['proof'] as Map)['channel_cases']}개',
                    '${(config!['proof'] as Map)['menu_count']} món · ${(config!['proof'] as Map)['channel_cases']} tuyến đã kiểm tra',
                    '${(config!['proof'] as Map)['menu_count']} menus · ${(config!['proof'] as Map)['channel_cases']} channel routes checked',
                  ),
                ),
              for (final path
                  in (config!['proof'] as Map?)?['paths'] as List? ?? [])
                ListTile(
                  title: Text('${path['channel']} · ${path['menu_count']}'),
                  subtitle: Text(
                    (path['path'] as List)
                        .map(
                          (id) =>
                              stations
                                  .where((s) => s['id'] == id)
                                  .map((s) => s['name'])
                                  .firstOrNull ??
                              '',
                        )
                        .join(' → '),
                  ),
                ),
              for (final device in config!['devices'] as List? ?? [])
                ListTile(
                  title: Text(
                    '${accounts.where((a) => a['id'] == device['user_id']).map((a) => a['name']).firstOrNull ?? ''} · ${device['seen_at']} · ${tr('미전송', 'Chưa gửi', 'Pending')} ${device['pending_count']}',
                  ),
                  trailing: IconButton(
                    tooltip: tr(
                      '오프라인 장치 등록 해제',
                      'Gỡ thiết bị ngoại tuyến',
                      'Remove offline device',
                    ),
                    onPressed: busy || device['pending_count'] != 0
                        ? null
                        : () => retireDevice(
                            Map<String, dynamic>.from(device as Map),
                          ),
                    icon: const Icon(Icons.phonelink_erase),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkflowMenuSearch extends StatefulWidget {
  const _WorkflowMenuSearch({required this.storeId});
  final String storeId;
  @override
  State<_WorkflowMenuSearch> createState() => _WorkflowMenuSearchState();
}

class _WorkflowMenuSearchState extends State<_WorkflowMenuSearch> {
  final query = TextEditingController();
  List<Map<String, dynamic>> items = [];
  bool busy = false;
  bool failed = false;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    if (busy) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final text = query.text
          .trim()
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      final result = await supabase
          .from('menu_items')
          .select('id,name,size_parent_id')
          .eq('restaurant_id', widget.storeId)
          .ilike('name', '%$text%')
          .order('name')
          .limit(50);
      if (mounted) {
        setState(() => items = List<Map<String, dynamic>>.from(result));
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String tr(String ko, String vi, String en) =>
        workflowText(Localizations.localeOf(context).languageCode, ko, vi, en);
    return AlertDialog(
      title: Text(tr('경로를 지정할 메뉴', 'Món cần đặt tuyến', 'Menu to route')),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: query,
              onSubmitted: (_) => search(),
              decoration: InputDecoration(
                labelText: tr(
                  '이름 검색 · 최대 50개',
                  'Tìm tên · tối đa 50',
                  'Search name · up to 50',
                ),
                suffixIcon: IconButton(
                  onPressed: busy ? null : search,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (failed)
              Text(
                tr(
                  '검색 실패. 다시 시도하세요.',
                  'Tìm thất bại. Thử lại.',
                  'Search failed. Retry.',
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final item in items)
                    ListTile(
                      title: Text('${item['name']}'),
                      onTap: () => Navigator.pop(context, item),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
