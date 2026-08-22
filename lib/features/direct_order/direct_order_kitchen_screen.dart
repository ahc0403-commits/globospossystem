import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_localization.dart';
import 'direct_order_staff_service.dart';

class DirectOrderKitchenScreen extends ConsumerStatefulWidget {
  const DirectOrderKitchenScreen({super.key});

  @override
  ConsumerState<DirectOrderKitchenScreen> createState() =>
      _DirectOrderKitchenScreenState();
}

class _DirectOrderKitchenScreenState
    extends ConsumerState<DirectOrderKitchenScreen> {
  Timer? _timer;
  List<Map<String, dynamic>> _tickets = const [];
  String? _filter;
  String? _error;
  bool _loading = true;
  final Set<String> _busyTickets = {};

  DirectOrderCopy get _copy =>
      DirectOrderCopy(Localizations.localeOf(context).languageCode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _timer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final storeId = ref.read(authProvider).storeId;
    if (storeId == null) return;
    if (!silent) setState(() => _loading = true);
    try {
      final tickets = await directOrderStaffService.listTickets(
        storeId: storeId,
        statuses: _filter == null ? null : [_filter!],
      );
      if (!mounted) return;
      setState(() {
        _tickets = tickets;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = _copy.loadFailed;
      });
    }
  }

  Future<void> _transition(Map<String, dynamic> ticket, String next) async {
    final storeId = ref.read(authProvider).storeId;
    final id = ticket['id']?.toString() ?? '';
    if (storeId == null || id.isEmpty || _busyTickets.contains(id)) return;
    setState(() => _busyTickets.add(id));
    try {
      await directOrderStaffService.transitionTicket(
        storeId: storeId,
        ticketId: id,
        expectedVersion: (ticket['version'] as num?)?.toInt() ?? 0,
        nextStatus: next,
      );
      await _load(silent: true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_copy.ticketConflict)));
        await _load(silent: true);
      }
    } finally {
      if (mounted) setState(() => _busyTickets.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    const filters = <String?>[
      null,
      'pending',
      'preparing',
      'ready',
      'dispatched',
      'completed',
    ];
    return Scaffold(
      backgroundColor: PosTerminalColors.darkShell,
      appBar: AppBar(
        backgroundColor: PosTerminalColors.darkRail,
        foregroundColor: PosTerminalColors.darkText,
        title: Text(_copy.kitchenBoard),
        actions: [
          IconButton(
            tooltip: _copy.refresh,
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          const LanguageSwitcher(compact: true),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: AppNavBar(
              showLogout: false,
              showLanguage: false,
              forceHomeEnabled: true,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: PosTerminalColors.darkRail,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final status in filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          status == null ? _copy.all : _copy.stateLabel(status),
                        ),
                        selected: _filter == status,
                        onSelected: (_) {
                          setState(() => _filter = status);
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _tickets.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tickets.isEmpty) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: PosTerminalColors.darkText),
        ),
      );
    }
    if (_tickets.isEmpty) {
      return Center(
        child: Text(
          _copy.noTickets,
          style: const TextStyle(
            color: PosTerminalColors.darkTextMuted,
            fontSize: 17,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1320
            ? 4
            : constraints.maxWidth >= 960
            ? 3
            : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: columns >= 3 ? 0.76 : 0.82,
          ),
          itemCount: _tickets.length,
          itemBuilder: (context, index) => _TicketCard(
            ticket: _tickets[index],
            copy: _copy,
            busy: _busyTickets.contains(_tickets[index]['id']?.toString()),
            onTransition: (next) => _transition(_tickets[index], next),
          ),
        );
      },
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({
    required this.ticket,
    required this.copy,
    required this.busy,
    required this.onTransition,
  });

  final Map<String, dynamic> ticket;
  final DirectOrderCopy copy;
  final bool busy;
  final ValueChanged<String> onTransition;

  @override
  Widget build(BuildContext context) {
    final status = ticket['status']?.toString() ?? 'pending';
    final items = ticket['items'] is List
        ? (ticket['items'] as List)
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : const <Map<String, dynamic>>[];
    final createdAt = DateTime.tryParse(ticket['created_at']?.toString() ?? '');
    final minutes = createdAt == null
        ? 0
        : DateTime.now()
              .difference(createdAt.toLocal())
              .inMinutes
              .clamp(0, 999);
    final next = switch (status) {
      'pending' => 'preparing',
      'preparing' => 'ready',
      'dispatched' => 'completed',
      _ => null,
    };
    final actionLabel = switch (next) {
      'preparing' => copy.startPreparing,
      'ready' => copy.markReady,
      'completed' => copy.markCompleted,
      _ => copy.waitingForDispatch,
    };

    return Semantics(
      label:
          '${copy.paidDirect}, ${ticket['pickup_code'] ?? ''}, ${copy.stateLabel(status)}',
      child: Card(
        color: PosTerminalColors.ticketPaper,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: _statusColor(status),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      copy.paidDirect,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    '${minutes}m',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '#${ticket['pickup_code'] ?? ''}',
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Chip(label: Text(copy.stateLabel(status))),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(14),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${item['quantity'] ?? 0}x',
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              localizedDirectOrderSnapshotName(
                                item,
                                Localizations.localeOf(context).languageCode,
                              ),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if ((item['note']?.toString() ?? '').isNotEmpty)
                              Text(
                                item['note'].toString(),
                                style: const TextStyle(
                                  color: PosColors.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: next == null
                  ? OutlinedButton(onPressed: null, child: Text(actionLabel))
                  : FilledButton(
                      onPressed: busy ? null : () => onTransition(next),
                      child: Text(actionLabel),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
    'pending' => PosStatusPalette.newOrder,
    'preparing' => PosStatusPalette.preparing,
    'ready' => PosStatusPalette.handoffReady,
    'dispatched' => PosColors.infoMuted,
    'completed' => PosColors.successMuted,
    _ => PosColors.panelMuted,
  };
}
