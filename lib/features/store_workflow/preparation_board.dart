import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/pos_backend.dart';
import '../../core/services/emergency_web_bridge.dart';
import '../../core/services/emergency_web_push_service.dart';
import '../../core/utils/floor_label.dart';
import 'workflow_service.dart';

class WorkflowDeviceBanner extends StatefulWidget {
  const WorkflowDeviceBanner({
    super.key,
    required this.storeId,
    required this.userId,
    required this.workflow,
    required this.legacyPending,
    this.service,
    this.onQuiesced,
  });
  final String storeId;
  final String userId;
  final Map<String, dynamic> workflow;
  final int legacyPending;
  final WorkflowService? service;
  final ValueChanged<bool>? onQuiesced;
  @override
  State<WorkflowDeviceBanner> createState() => _WorkflowDeviceBannerState();
}

class _WorkflowDeviceBannerState extends State<WorkflowDeviceBanner> {
  bool busy = false;
  String? acknowledged;
  bool quiesced = false;
  String? error;
  Timer? heartbeat;
  String tr(String ko, String vi, String en) =>
      workflowText(Localizations.localeOf(context).languageCode, ko, vi, en);
  @override
  void initState() {
    super.initState();
    heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (acknowledged != null) unawaited(ack(acknowledged!));
    });
  }

  @override
  void didUpdateWidget(WorkflowDeviceBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.userId != widget.userId) {
      acknowledged = null;
      error = null;
    }
    if (acknowledged != widget.workflow['active_id'] &&
        acknowledged != widget.workflow['candidate_id']) {
      acknowledged = null;
    }
  }

  @override
  void dispose() {
    heartbeat?.cancel();
    super.dispose();
  }

  Future<void> ack(String release, {bool withdraw = false}) async {
    if (busy) return;
    setState(() => busy = true);
    final store = widget.storeId;
    final user = widget.userId;
    try {
      final pending = await WorkflowOutbox(store, user).read();
      await (widget.service ?? WorkflowService()).acknowledge(
        store,
        release,
        withdraw ? -1 : widget.legacyPending + (pending == null ? 0 : 1),
      );
      if (!mounted || store != widget.storeId || user != widget.userId) return;
      setState(() {
        acknowledged = withdraw ? null : release;
        quiesced =
            !withdraw &&
            widget.workflow['active_id'] != release &&
            widget.legacyPending == 0 &&
            pending == null;
        error = null;
      });
      widget.onQuiesced?.call(quiesced);
    } catch (_) {
      if (mounted && store == widget.storeId && user == widget.userId) {
        setState(
          () => error = tr(
            '장치 확인 실패. 다시 시도하세요.',
            'Không thể xác nhận thiết bị. Thử lại.',
            'Device check failed. Retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final release =
        widget.workflow['candidate_id'] ?? widget.workflow['active_id'];
    if (release is! String) return const SizedBox.shrink();
    final station =
        widget.workflow['candidate_station'] ?? widget.workflow['station'];
    final waiting = quiesced || widget.workflow['quiesced'] == true;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: ListTile(
        title: Text(
          tr(
            '게시 설정 장치 확인',
            'Xác nhận thiết bị cho cấu hình',
            'Confirm device for published setup',
          ),
        ),
        subtitle: Text(
          error ??
              '${station is Map ? station['name'] : tr('현재 담당 유지', 'Giữ phân công hiện tại', 'Keep current assignment')} · ${tr('미전송', 'Chưa gửi', 'Pending')} ${widget.legacyPending}',
        ),
        trailing: TextButton(
          onPressed: busy ? null : () => ack(release, withdraw: waiting),
          child: Text(
            waiting
                ? tr('전환 대기 해제', 'Hủy chờ chuyển', 'Leave switch waiting mode')
                : acknowledged == release
                ? tr('확인됨', 'Đã xác nhận', 'Confirmed')
                : tr('담당 확인', 'Xác nhận', 'Confirm assignment'),
          ),
        ),
      ),
    );
  }
}

class PreparationBoard extends StatefulWidget {
  const PreparationBoard({
    super.key,
    required this.storeId,
    required this.userId,
    required this.workflow,
    this.legacyPending = 0,
    this.service,
    this.packagingPanel,
    this.navigation,
  });
  final String storeId;
  final String userId;
  final Map<String, dynamic> workflow;
  final int legacyPending;
  final WorkflowService? service;
  final Widget? packagingPanel;
  final Widget? navigation;
  @override
  State<PreparationBoard> createState() => _PreparationBoardState();
}

class _PreparationBoardState extends State<PreparationBoard> {
  late WorkflowService service;
  Map<String, dynamic>? snapshot;
  Map<String, dynamic>? cursor;
  Map<String, dynamic>? pending;
  bool busy = false;
  bool completed = false;
  bool alarmEnabled = false;
  bool flashing = false;
  Timer? flashTimer;
  Map<String, int>? knownReady;
  bool conflict = false;
  bool quiesced = false;
  String? error;
  Timer? poll;
  RealtimeChannel? channel;
  int generation = 0;
  String tr(String ko, String vi, String en) =>
      workflowText(Localizations.localeOf(context).languageCode, ko, vi, en);
  WorkflowOutbox get outbox => WorkflowOutbox(widget.storeId, widget.userId);
  @override
  void initState() {
    super.initState();
    service = widget.service ?? WorkflowService();
    unawaited(refresh());
    poll = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(refresh()),
    );
    subscribe();
  }

  void subscribe() {
    if (widget.service != null) return;
    final station = widget.workflow['station'];
    if (station is! Map) return;
    channel = supabase
        .channel(
          'workflow:${widget.storeId}:${station['id']}:${widget.workflow['active_id']}',
          opts: const RealtimeChannelConfig(private: true),
        )
        .onBroadcast(event: 'changed', callback: (_) => unawaited(refresh()))
        .subscribe();
  }

  @override
  void didUpdateWidget(PreparationBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.userId != widget.userId ||
        oldWidget.workflow['active_id'] != widget.workflow['active_id']) {
      generation++;
      snapshot = cursor = pending = null;
      knownReady = null;
      error = null;
      conflict = false;
      if (channel != null) unawaited(supabase.removeChannel(channel!));
      subscribe();
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    generation++;
    poll?.cancel();
    flashTimer?.cancel();
    if (channel != null) unawaited(supabase.removeChannel(channel!));
    super.dispose();
  }

  Future<void> refresh() async {
    if (busy || conflict) return;
    final epoch = generation;
    final scopedOutbox = outbox;
    final store = widget.storeId;
    setState(() => busy = true);
    try {
      final queued = await scopedOutbox.read();
      if (queued != null) {
        if (mounted && epoch == generation) setState(() => pending = queued);
        await service.progress(store, queued);
        await scopedOutbox.clear();
      }
      final result = await service.snapshot(
        store,
        after: cursor,
        completed: completed,
      );
      if (!mounted || epoch != generation) return;
      if (result['release_id'] != widget.workflow['active_id']) {
        throw const FormatException('WORKFLOW_RELEASE_CHANGED');
      }
      if (!completed && cursor == null) {
        final ready = <String, int>{
          for (final row in result['items'] as List? ?? [])
            if ((row['available'] as num) > (row['started'] as num))
              row['id'] as String: (row['available'] as num).toInt(),
        };
        final changed =
            knownReady != null &&
            ready.entries.any((row) => row.value > (knownReady![row.key] ?? 0));
        knownReady = ready;
        if (changed) {
          flashing = true;
          flashTimer?.cancel();
          flashTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => flashing = false);
          });
          if (alarmEnabled) {
            unawaited(
              EmergencyWebBridge.speak(
                tr(
                  '새 조리 작업을 확인하세요.',
                  'Có công việc bếp mới. Vui lòng kiểm tra.',
                  'New kitchen work is ready. Please check.',
                ),
              ),
            );
          }
        }
      }
      setState(() {
        snapshot = result;
        pending = null;
        error = null;
        conflict = false;
      });
    } on PostgrestException catch (e) {
      if (!mounted || epoch != generation) return;
      setState(() {
        conflict = e.message == 'WORKFLOW_PROGRESS_CHANGED';
        error = conflict
            ? tr(
                '수량 또는 단계가 변경되었습니다. 미반영 요청을 해제하고 다시 선택하세요.',
                'Số lượng hoặc bước đã thay đổi. Bỏ yêu cầu chưa áp dụng rồi chọn lại.',
                'Quantity or stage changed. Clear the unapplied request and select again.',
              )
            : tr(
                '동기화 실패. 같은 요청으로 다시 시도합니다.',
                'Đồng bộ thất bại. Thử lại cùng yêu cầu.',
                'Sync failed. Retry the same request.',
              );
      });
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(
          () => error = tr(
            '연결을 확인하고 재시도하세요. 요청은 보관됩니다.',
            'Kiểm tra kết nối và thử lại. Yêu cầu được giữ lại.',
            'Check the connection and retry. The request is retained.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (epoch != generation) unawaited(refresh());
      }
    }
  }

  Future<void> act(Map<String, dynamic> item, String action) async {
    final epoch = generation;
    final remaining = switch (action) {
      'start' =>
        (item['available'] as num).toInt() - (item['started'] as num).toInt(),
      'done' =>
        (item['started'] as num).toInt() - (item['done'] as num).toInt(),
      'undo_start' => (item['undo_start_available'] as num).toInt(),
      _ => (item['undo_done_available'] as num).toInt(),
    };
    final count = await showDialog<int>(
      context: context,
      builder: (_) => _QuantityDialog(
        maximum: remaining,
        title: action.startsWith('undo_')
            ? tr('되돌릴 수량', 'Số lượng hoàn tác', 'Quantity to undo')
            : action == 'start'
            ? tr('조리 시작 수량', 'Số lượng bắt đầu', 'Quantity to start')
            : tr('완료·인계 수량', 'Số lượng hoàn tất', 'Quantity to complete'),
      ),
    );
    if (count == null ||
        !mounted ||
        busy ||
        error != null ||
        epoch != generation ||
        quiesced) {
      return;
    }
    setState(() => busy = true);
    try {
      await outbox.save({
        'p_event_id': const Uuid().v4(),
        'p_action': action,
        'p_allocations': [
          {
            'step_id': item['id'],
            'revision': item['revision'],
            'quantity': count,
          },
        ],
      });
      if (!mounted) return;
      setState(() => busy = false);
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            '요청 보관 실패. 다시 시도하세요.',
            'Không thể lưu yêu cầu. Thử lại.',
            'Could not retain the request. Retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final items = (snapshot?['items'] as List? ?? []).cast<Map>();
    return Scaffold(
      key: const Key('multi_kitchen_board'),
      bottomNavigationBar: widget.navigation,
      appBar: AppBar(
        title: Text(
          '${(widget.workflow['station'] as Map?)?['name'] ?? tr('주방', 'Bếp', 'Kitchen')}',
        ),
        backgroundColor: flashing
            ? Theme.of(context).colorScheme.tertiaryContainer
            : null,
        actions: [
          IconButton(
            tooltip: tr('조리 알림 켜기', 'Bật báo bếp', 'Enable kitchen alerts'),
            onPressed: alarmEnabled
                ? null
                : () async {
                    final enabled = await EmergencyWebBridge.enableVoice();
                    await EmergencyWebPushService.instance.enable(
                      storeId: widget.storeId,
                    );
                    if (mounted) setState(() => alarmEnabled = enabled);
                  },
            icon: Icon(
              alarmEnabled
                  ? Icons.notifications_active
                  : Icons.notifications_none,
            ),
          ),
          IconButton(
            onPressed: busy ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          WorkflowDeviceBanner(
            storeId: widget.storeId,
            userId: widget.userId,
            workflow: widget.workflow,
            legacyPending: widget.legacyPending,
            onQuiesced: (value) {
              if (mounted) setState(() => quiesced = value);
            },
            service: widget.service,
          ),
          if (busy) const LinearProgressIndicator(),
          SwitchListTile(
            title: Text(
              tr(
                '최근 24시간 완료',
                'Đã xong trong 24 giờ',
                'Completed in the last 24 hours',
              ),
            ),
            value: completed,
            onChanged: busy
                ? null
                : (value) {
                    setState(() {
                      completed = value;
                      cursor = null;
                    });
                    unawaited(refresh());
                  },
          ),
          if (error != null)
            ListTile(
              title: Text(error!),
              trailing: conflict && pending != null
                  ? TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              await outbox.clear();
                              if (mounted) {
                                setState(() {
                                  pending = null;
                                  conflict = false;
                                });
                                await refresh();
                              }
                            },
                      child: Text(
                        tr(
                          '미반영 요청 해제',
                          'Bỏ yêu cầu',
                          'Clear unapplied request',
                        ),
                      ),
                    )
                  : null,
            ),
          Expanded(
            child: ListView(
              children: [
                if (widget.packagingPanel != null) widget.packagingPanel!,
                if (items.isEmpty && error == null && !busy)
                  ListTile(
                    title: Text(
                      tr(
                        '대기 중인 조리가 없습니다.',
                        'Không có món đang chờ.',
                        'No preparation is pending.',
                      ),
                    ),
                  ),
                for (final raw in items)
                  Builder(
                    builder: (context) {
                      final item = Map<String, dynamic>.from(raw);
                      final available = (item['available'] as num).toInt();
                      final started = (item['started'] as num).toInt();
                      final done = (item['done'] as num).toInt();
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${item['name_$lang'] ?? item['name_en']}',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                '${item['table_number'] ?? ''} ${item['floor_label'] == null ? '' : displayFloorLabel(item['floor_label'] as String)}',
                              ),
                              if ((item['notes'] as String? ?? '').isNotEmpty)
                                Text(item['notes'] as String),
                              Text(
                                '${tr('가능', 'Có thể', 'Available')} $available · ${tr('시작', 'Bắt đầu', 'Started')} $started · ${tr('완료', 'Hoàn tất', 'Done')} $done / ${item['quantity']}',
                              ),
                              if (item['ready_at'] is String)
                                Text(
                                  '${tr('경과', 'Đã chờ', 'Elapsed')} ${DateTime.now().toUtc().difference(DateTime.parse(item['started_at'] as String? ?? item['ready_at'] as String)).inMinutes.clamp(0, 9999)} ${tr('분', 'phút', 'min')}',
                                ),
                              Wrap(
                                spacing: 12,
                                children: [
                                  for (final action in [
                                    'undo_start',
                                    'undo_done',
                                  ])
                                    if (((item['${action}_available'] as num?)
                                                ?.toInt() ??
                                            0) >
                                        0)
                                      TextButton(
                                        onPressed:
                                            busy ||
                                                quiesced ||
                                                error != null ||
                                                pending != null
                                            ? null
                                            : () => act(item, action),
                                        child: Text(
                                          action == 'undo_start'
                                              ? tr(
                                                  '시작 되돌리기',
                                                  'Hoàn tác bắt đầu',
                                                  'Undo start',
                                                )
                                              : tr(
                                                  '완료 되돌리기',
                                                  'Hoàn tác hoàn tất',
                                                  'Undo completion',
                                                ),
                                        ),
                                      ),
                                  OutlinedButton(
                                    onPressed:
                                        busy ||
                                            quiesced ||
                                            error != null ||
                                            pending != null ||
                                            available <= started
                                        ? null
                                        : () => act(item, 'start'),
                                    child: Text(
                                      tr(
                                        '조리 시작',
                                        'Bắt đầu nấu',
                                        'Start cooking',
                                      ),
                                    ),
                                  ),
                                  FilledButton(
                                    onPressed:
                                        busy ||
                                            quiesced ||
                                            error != null ||
                                            pending != null ||
                                            started <= done
                                        ? null
                                        : () => act(item, 'done'),
                                    child: Text(
                                      item['final_step'] == true
                                          ? tr(
                                              '최종 인계',
                                              'Bàn giao cuối',
                                              'Final handoff',
                                            )
                                          : tr(
                                              '다음 주방 인계',
                                              'Chuyển bếp tiếp theo',
                                              'Pass to next kitchen',
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                Wrap(
                  children: [
                    if (cursor != null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () {
                                setState(() => cursor = null);
                                unawaited(refresh());
                              },
                        child: Text(tr('처음', 'Đầu tiên', 'First page')),
                      ),
                    if (snapshot?['has_more'] == true && items.isNotEmpty)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () {
                                setState(
                                  () => cursor = Map<String, dynamic>.from(
                                    items.last,
                                  ),
                                );
                                unawaited(refresh());
                              },
                        child: Text(tr('다음 100개', '100 mục tiếp', 'Next 100')),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.maximum, required this.title});
  final int maximum;
  final String title;
  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  int quantity = 1;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: quantity > 1 ? () => setState(() => quantity--) : null,
          icon: const Icon(Icons.remove),
        ),
        Text('$quantity / ${widget.maximum}'),
        IconButton(
          onPressed: quantity < widget.maximum
              ? () => setState(() => quantity++)
              : null,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, quantity),
        child: Text(MaterialLocalizations.of(context).okButtonLabel),
      ),
    ],
  );
}
