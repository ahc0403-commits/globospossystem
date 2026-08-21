import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/live_refresh_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../auth/auth_provider.dart';
import 'direct_order_arrival_alert_service.dart';
import 'direct_order_arrival_alert_sound.dart';
import 'direct_order_copy.dart';

class DirectOrderArrivalAlertMetric {
  const DirectOrderArrivalAlertMetric({
    required this.stage,
    required this.success,
    required this.count,
    required this.latencyMs,
  });

  final String stage;
  final bool success;
  final int count;
  final int latencyMs;
}

class DirectOrderArrivalAlertHost extends ConsumerStatefulWidget {
  const DirectOrderArrivalAlertHost({
    super.key,
    required this.child,
    this.service,
    this.soundService,
    this.liveEvents,
    this.pollInterval = const Duration(seconds: 10),
    this.burstWindow = const Duration(milliseconds: 500),
    this.storeIdOverride,
    this.enabledOverride,
    this.onViewOrders,
    this.onPresented,
    this.onMetric,
  });

  final Widget child;
  final DirectOrderArrivalAlertService? service;
  final DirectOrderArrivalAlertSoundService? soundService;
  final Stream<PosLiveEvent>? liveEvents;
  final Duration pollInterval;
  final Duration burstWindow;
  final String? storeIdOverride;
  final bool? enabledOverride;
  final VoidCallback? onViewOrders;
  final ValueChanged<int>? onPresented;
  final ValueChanged<DirectOrderArrivalAlertMetric>? onMetric;

  @override
  ConsumerState<DirectOrderArrivalAlertHost> createState() =>
      _DirectOrderArrivalAlertHostState();
}

class _DirectOrderArrivalAlertHostState
    extends ConsumerState<DirectOrderArrivalAlertHost> {
  Timer? _pollTimer;
  Timer? _burstTimer;
  StreamSubscription<PosLiveEvent>? _signalSubscription;
  DirectOrderArrivalCursor? _cursor;
  _DirectOrderArrivalNotice? _notice;
  String? _desiredStoreId;
  String? _activeStoreId;
  int _generation = 0;
  bool _initializing = false;
  bool _draining = false;
  bool _retryRequested = false;
  bool _insertSignalDuringInitialization = false;

  DirectOrderArrivalAlertService get _service =>
      widget.service ?? directOrderArrivalAlertService;
  DirectOrderArrivalAlertSoundService get _sound =>
      widget.soundService ?? directOrderArrivalAlertSoundService;

  @override
  void didUpdateWidget(DirectOrderArrivalAlertHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        oldWidget.liveEvents != widget.liveEvents ||
        oldWidget.pollInterval != widget.pollInterval ||
        oldWidget.storeIdOverride != widget.storeIdOverride ||
        oldWidget.enabledOverride != widget.enabledOverride) {
      _desiredStoreId = null;
    }
  }

  @override
  void dispose() {
    _generation += 1;
    _pollTimer?.cancel();
    _burstTimer?.cancel();
    unawaited(_signalSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? storeId;
    if (widget.enabledOverride != null &&
        (widget.storeIdOverride != null || widget.enabledOverride == false)) {
      storeId = widget.enabledOverride == true ? widget.storeIdOverride : null;
    } else {
      final auth = ref.watch(authProvider);
      final enabled = widget.enabledOverride ?? auth.role == 'cashier';
      storeId = enabled ? (widget.storeIdOverride ?? auth.storeId) : null;
    }
    _scheduleStore(storeId);

    if (storeId != null && widget.liveEvents == null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          _handleLiveEvent(event);
        });
      });
    }

    final notice = _notice;
    return Listener(
      onPointerDown: (_) {
        if (_activeStoreId != null) {
          unawaited(_sound.prepare().catchError((_) {}));
        }
      },
      child: Stack(
        children: [
          widget.child,
          if (notice != null)
            Align(
              alignment: Alignment.topRight,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: DirectOrderArrivalAlertBanner(
                    count: notice.count,
                    pendingCount: notice.pendingCount,
                    onClose: () {
                      if (mounted) setState(() => _notice = null);
                    },
                    onViewOrders: () {
                      if (mounted) setState(() => _notice = null);
                      final callback = widget.onViewOrders;
                      if (callback != null) {
                        callback();
                      } else {
                        context.go('/cashier/direct-orders');
                      }
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _scheduleStore(String? storeId) {
    if (_desiredStoreId == storeId) return;
    _desiredStoreId = storeId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _desiredStoreId == storeId) _activateStore(storeId);
    });
  }

  void _activateStore(String? storeId) {
    _generation += 1;
    final generation = _generation;
    _pollTimer?.cancel();
    _burstTimer?.cancel();
    unawaited(_signalSubscription?.cancel());
    _signalSubscription = null;
    _activeStoreId = storeId;
    _cursor = null;
    _initializing = false;
    _draining = false;
    _retryRequested = false;
    _insertSignalDuringInitialization = false;
    if (mounted && _notice != null) setState(() => _notice = null);
    if (storeId == null) return;

    final injectedEvents = widget.liveEvents;
    if (injectedEvents != null) {
      _signalSubscription = injectedEvents.listen(
        _handleLiveEvent,
        onError: (_) {},
      );
    }
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _requestDrain());
    unawaited(_initializeCursor(generation, storeId));
  }

  Future<void> _initializeCursor(int generation, String storeId) async {
    if (_initializing || _cursor != null) return;
    _initializing = true;
    final stopwatch = Stopwatch()..start();
    var success = false;
    var loadedExisting = false;
    var baselinePendingCount = 0;
    try {
      final loaded = await _service.loadCursor(storeId);
      if (!mounted || generation != _generation) return;
      if (loaded != null) {
        _cursor = loaded;
        loadedExisting = true;
      } else {
        final baseline = await _service.fetchAfter(storeId, null);
        if (!mounted || generation != _generation) return;
        await _service.saveCursor(storeId, baseline.nextCursor);
        if (!mounted || generation != _generation) return;
        _cursor = baseline.nextCursor;
        baselinePendingCount = baseline.pendingCount;
      }
      success = true;
    } catch (_) {
      // Polling retries initialization. No direct alert failure escapes host.
    } finally {
      _initializing = false;
      _emitMetric('initialize', success, 0, stopwatch.elapsedMilliseconds);
    }
    if (!mounted || generation != _generation) return;
    if (!loadedExisting && _insertSignalDuringInitialization) {
      _insertSignalDuringInitialization = false;
      _retryRequested = false;
      unawaited(
        _drain(generation, storeId, fallbackPendingCount: baselinePendingCount),
      );
      return;
    }
    if (loadedExisting || _retryRequested) _requestDrain(immediate: true);
  }

  void _handleLiveEvent(PosLiveEvent event) {
    if (!event.affects({'direct_orders'})) return;
    if (_cursor == null &&
        _initializing &&
        event.domain == 'direct_orders' &&
        event.sourceTable == 'direct_order_requests' &&
        event.eventType == 'INSERT') {
      _insertSignalDuringInitialization = true;
    }
    _requestDrain();
  }

  void _requestDrain({bool immediate = false}) {
    final storeId = _activeStoreId;
    if (storeId == null) return;
    _retryRequested = true;
    if (_cursor == null) {
      unawaited(_initializeCursor(_generation, storeId));
      return;
    }
    if (_initializing || _draining) return;
    _burstTimer?.cancel();
    if (immediate) {
      unawaited(_drain(_generation, storeId));
    } else {
      _burstTimer = Timer(
        widget.burstWindow,
        () => unawaited(_drain(_generation, storeId)),
      );
    }
  }

  Future<void> _drain(
    int generation,
    String storeId, {
    int? fallbackPendingCount,
  }) async {
    if (_draining || _cursor == null || generation != _generation) return;
    _draining = true;
    _retryRequested = false;
    final stopwatch = Stopwatch()..start();
    var success = false;
    final arrivals = <DirectOrderArrival>[];
    final seenRequestIds = <String>{};
    var pendingCount = 0;
    try {
      for (var page = 0; page < 100; page += 1) {
        final before = _cursor!;
        final batch = await _service.fetchAfter(storeId, before);
        if (!mounted || generation != _generation) return;
        if (batch.nextCursor != before) {
          await _service.saveCursor(storeId, batch.nextCursor);
          if (!mounted || generation != _generation) return;
          _cursor = batch.nextCursor;
        }
        pendingCount = batch.pendingCount;
        for (final arrival in batch.items) {
          if (seenRequestIds.add(arrival.requestId)) arrivals.add(arrival);
        }
        if (!batch.hasMore) break;
        if (batch.nextCursor == before) {
          throw const FormatException('Arrival cursor did not advance');
        }
      }
      success = true;
      final presentedCount = arrivals.isNotEmpty
          ? arrivals.length
          : fallbackPendingCount == null
          ? 0
          : 1;
      if (presentedCount > 0 && mounted && generation == _generation) {
        final displayedPendingCount = arrivals.isNotEmpty
            ? pendingCount
            : fallbackPendingCount!;
        _present(presentedCount, displayedPendingCount);
        _emitMetric(
          'display',
          true,
          presentedCount,
          stopwatch.elapsedMilliseconds,
        );
        unawaited(_playChime(presentedCount));
      }
    } catch (_) {
      // Realtime and polling failures are contained and retried by the host.
    } finally {
      _draining = false;
      _emitMetric(
        'drain',
        success,
        arrivals.length,
        stopwatch.elapsedMilliseconds,
      );
      if (_retryRequested && mounted && generation == _generation) {
        _requestDrain();
      }
    }
  }

  void _present(int count, int pendingCount) {
    setState(
      () => _notice = _DirectOrderArrivalNotice(
        count: count,
        pendingCount: pendingCount,
      ),
    );
    try {
      widget.onPresented?.call(count);
    } catch (_) {}
  }

  Future<void> _playChime(int count) async {
    final stopwatch = Stopwatch()..start();
    var success = false;
    try {
      await _sound.play();
      success = true;
    } catch (_) {
      // Browser autoplay/audio failure must not hide or repeat the alert.
    }
    _emitMetric('chime', success, count, stopwatch.elapsedMilliseconds);
  }

  void _emitMetric(String stage, bool success, int count, int latencyMs) {
    try {
      widget.onMetric?.call(
        DirectOrderArrivalAlertMetric(
          stage: stage,
          success: success,
          count: count,
          latencyMs: latencyMs,
        ),
      );
    } catch (_) {}
  }
}

class DirectOrderArrivalAlertBanner extends StatelessWidget {
  const DirectOrderArrivalAlertBanner({
    super.key,
    required this.count,
    required this.pendingCount,
    required this.onClose,
    required this.onViewOrders,
  });

  final int count;
  final int pendingCount;
  final VoidCallback onClose;
  final VoidCallback onViewOrders;

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(Localizations.localeOf(context).languageCode);
    return Semantics(
      liveRegion: true,
      label: '${copy.arrivalAlertTitle}. ${copy.arrivalAlertBody(count)}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Material(
          key: const Key('direct_order_arrival_alert_banner'),
          color: PosColors.surface,
          elevation: 8,
          borderRadius: AppRadius.md,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              border: Border.all(color: PosColors.accent, width: 2),
              borderRadius: AppRadius.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.delivery_dining_rounded,
                    color: PosColors.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        copy.arrivalAlertTitle,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 3),
                      Text(copy.arrivalAlertBody(count)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(copy.arrivalPendingChip(pendingCount)),
                          ),
                          TextButton(
                            onPressed: onViewOrders,
                            child: Text(copy.viewArrivalOrder),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: copy.close,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectOrderArrivalNotice {
  const _DirectOrderArrivalNotice({
    required this.count,
    required this.pendingCount,
  });

  final int count;
  final int pendingCount;
}
