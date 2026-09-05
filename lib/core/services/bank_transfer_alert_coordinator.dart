import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../widgets/error_toast.dart';
import '../i18n/locale_extensions.dart';
import 'bank_transfer_alert_service.dart';
import 'bank_transfer_alert_sound.dart';
import 'live_refresh_service.dart';

/// Owns the SePay alert cursor at app scope so desktop locks, minimization, and
/// route changes do not tear down the polling/realtime recovery loop.
class BankTransferAlertCoordinator extends ConsumerStatefulWidget {
  const BankTransferAlertCoordinator({
    super.key,
    required this.storeId,
    required this.child,
    this.alertService,
    this.soundService,
    this.pollInterval = const Duration(seconds: 2),
  });

  final String? storeId;
  final Widget child;
  final BankTransferAlertService? alertService;
  final BankTransferAlertSoundService? soundService;
  final Duration pollInterval;

  @override
  ConsumerState<BankTransferAlertCoordinator> createState() =>
      _BankTransferAlertCoordinatorState();
}

class _BankTransferAlertCoordinatorState
    extends ConsumerState<BankTransferAlertCoordinator> {
  Timer? _pollTimer;
  String? _activeStoreId;
  BankTransferAlertCursor? _cursor;
  bool _inFlight = false;
  bool _retryRequested = false;
  int _generation = 0;

  BankTransferAlertService get _alertService =>
      widget.alertService ?? bankTransferAlertService;
  BankTransferAlertSoundService get _soundService =>
      widget.soundService ?? bankTransferAlertSoundService;

  @override
  void initState() {
    super.initState();
    _switchStore(widget.storeId);
  }

  @override
  void didUpdateWidget(BankTransferAlertCoordinator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.alertService != widget.alertService ||
        oldWidget.pollInterval != widget.pollInterval) {
      _switchStore(widget.storeId);
    }
  }

  void _switchStore(String? storeId) {
    final generation = ++_generation;
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeStoreId = storeId;
    _cursor = null;
    _retryRequested = false;
    if (storeId != null) unawaited(_start(storeId, generation));
  }

  Future<void> _start(String storeId, int generation) async {
    try {
      await _alertService.registerPollingDevice(storeId);
    } catch (_) {
      // Ordered polling still works while the delivery ledger is unavailable.
    }
    final cursor =
        await _alertService.loadCursor(storeId) ??
        BankTransferAlertCursor.startedNow();
    if (!mounted || generation != _generation || _activeStoreId != storeId) {
      return;
    }
    _cursor = cursor;
    _pollTimer = Timer.periodic(
      widget.pollInterval,
      (_) => unawaited(_drain(storeId)),
    );
    await _drain(storeId);
  }

  Future<void> _drain(String storeId) async {
    if (_inFlight) {
      _retryRequested = true;
      return;
    }
    _inFlight = true;
    try {
      var shouldContinue = true;
      while (shouldContinue) {
        _retryRequested = false;
        final cursor = _cursor;
        if (!mounted || _activeStoreId != storeId || cursor == null) return;

        final alerts = await _alertService.fetchAfter(storeId, cursor);
        for (final alert in alerts) {
          if (!mounted || _activeStoreId != storeId) return;
          if (!cursor.isBefore(alert)) continue;

          final amount = NumberFormat('#,###', 'vi_VN').format(alert.amount);
          showSuccessToast(
            context,
            context.l10n.cashierBankTransferReceived(
              amount,
              alert.paymentCode ?? '-',
            ),
          );
          try {
            await _alertService.acknowledge(alert.transactionId, spoken: false);
          } catch (_) {
            // Delivery acknowledgements are observability, not an alert gate.
          }

          var spoken = false;
          try {
            await _soundService.play(amount: alert.amount);
            spoken = true;
          } catch (_) {
            // The amount toast remains authoritative if audio is unavailable.
          }
          if (spoken) {
            try {
              await _alertService.acknowledge(
                alert.transactionId,
                spoken: true,
              );
            } catch (_) {
              // The persisted cursor prevents duplicate speech on ack failure.
            }
          }

          if (!mounted || _activeStoreId != storeId) return;
          cursor.advance(alert);
          await _alertService.saveCursor(storeId, cursor);
        }
        shouldContinue = alerts.length >= 100 || _retryRequested;
      }
    } catch (_) {
      // The next realtime signal or poll retries transient RPC/storage errors.
    } finally {
      _inFlight = false;
      if (_retryRequested && mounted && _activeStoreId == storeId) {
        unawaited(_drain(storeId));
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _generation += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storeId = widget.storeId;
    if (storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          if (event.includesChange(
            domain: 'bank_transfer',
            sourceTable: 'sepay_transactions',
            eventType: 'INSERT',
          )) {
            unawaited(_drain(storeId));
          }
        });
      });
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => unawaited(_soundService.prepare()),
      child: widget.child,
    );
  }
}
