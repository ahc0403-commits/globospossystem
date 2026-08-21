import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_staff_service.dart';

class DirectOrderAnalyticsScreen extends ConsumerStatefulWidget {
  const DirectOrderAnalyticsScreen({super.key});

  @override
  ConsumerState<DirectOrderAnalyticsScreen> createState() =>
      _DirectOrderAnalyticsScreenState();
}

class _DirectOrderAnalyticsScreenState
    extends ConsumerState<DirectOrderAnalyticsScreen> {
  final _money = NumberFormat('#,###', 'vi_VN');
  Map<String, dynamic>? _data;
  int _days = 7;
  bool _loading = true;
  String? _error;

  DirectOrderCopy get _copy =>
      DirectOrderCopy(Localizations.localeOf(context).languageCode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final storeId = ref.read(authProvider).storeId;
    if (storeId == null) return;
    setState(() => _loading = true);
    final to = DateTime.now();
    final from = DateTime(
      to.year,
      to.month,
      to.day,
    ).subtract(Duration(days: _days - 1));
    try {
      final data = await directOrderStaffService.analytics(
        storeId: storeId,
        from: from,
        to: to,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _copy.loadFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _map(_data?['summary']);
    final daily = _maps(_data?['daily']);
    final hourly = _maps(_data?['hourly']);
    final regions = _maps(_data?['regions']);
    return Scaffold(
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        title: Text(_copy.analytics),
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
            child: AppNavBar(showLogout: false, showLanguage: false),
          ),
        ],
      ),
      body: _loading && _data == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _data == null
          ? Center(child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text(_copy.today),
                      selected: _days == 1,
                      onSelected: (_) => _setDays(1),
                    ),
                    ChoiceChip(
                      label: Text(_copy.last7Days),
                      selected: _days == 7,
                      onSelected: (_) => _setDays(7),
                    ),
                    ChoiceChip(
                      label: Text(_copy.last30Days),
                      selected: _days == 30,
                      onSelected: (_) => _setDays(30),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth >= 1000
                        ? (constraints.maxWidth - 48) / 4
                        : constraints.maxWidth >= 620
                        ? (constraints.maxWidth - 16) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        _Kpi(
                          width: width,
                          label: _copy.grossSales,
                          value: _vnd(summary['gross_sales']),
                          icon: Icons.payments_outlined,
                        ),
                        _Kpi(
                          width: width,
                          label: _copy.orderCount,
                          value: '${_number(summary['order_count']).toInt()}',
                          icon: Icons.receipt_long_outlined,
                        ),
                        _Kpi(
                          width: width,
                          label: _copy.deliveryFeeSales,
                          value: _vnd(summary['delivery_fee_sales']),
                          icon: Icons.delivery_dining_outlined,
                        ),
                        _Kpi(
                          width: width,
                          label: '${_copy.grabCost} / ${_copy.feeVariance}',
                          value:
                              '${_vnd(summary['grab_cost'])} / ${_vnd(summary['delivery_fee_variance'])}',
                          icon: Icons.balance_outlined,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                if (_number(summary['order_count']) == 0)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text(_copy.noAnalytics)),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 950;
                      final first = _BarPanel(
                        title: _copy.ordersByHour,
                        rows: hourly,
                        label: (row) =>
                            '${(row['hour'] as num?)?.toInt().toString().padLeft(2, '0') ?? '--'}:00',
                        value: (row) => _number(row['order_count']),
                        valueLabel: (row) =>
                            '${_number(row['order_count']).toInt()}',
                      );
                      final second = _BarPanel(
                        title: _copy.dailySales,
                        rows: daily,
                        label: (row) => row['date']?.toString() ?? '',
                        value: (row) => _number(row['gross_sales']),
                        valueLabel: (row) => _vnd(row['gross_sales']),
                      );
                      return wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: first),
                                const SizedBox(width: 16),
                                Expanded(child: second),
                              ],
                            )
                          : Column(
                              children: [
                                first,
                                const SizedBox(height: 16),
                                second,
                              ],
                            );
                    },
                  ),
                const SizedBox(height: 16),
                _RegionPanel(regions: regions, copy: _copy),
              ],
            ),
    );
  }

  void _setDays(int days) {
    setState(() => _days = days);
    _load();
  }

  String _vnd(Object? value) => '${_money.format(_number(value))} VND';
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.width,
    required this.label,
    required this.value,
    required this.icon,
  });
  final double width;
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: PosColors.accentMuted,
              child: Icon(icon, color: PosColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: PosColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BarPanel extends StatelessWidget {
  const _BarPanel({
    required this.title,
    required this.rows,
    required this.label,
    required this.value,
    required this.valueLabel,
  });
  final String title;
  final List<Map<String, dynamic>> rows;
  final String Function(Map<String, dynamic>) label;
  final double Function(Map<String, dynamic>) value;
  final String Function(Map<String, dynamic>) valueLabel;
  @override
  Widget build(BuildContext context) {
    final maxValue = rows.fold<double>(
      0,
      (current, row) => value(row) > current ? value(row) : current,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    SizedBox(width: 74, child: Text(label(row))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: AppRadius.pill,
                        child: LinearProgressIndicator(
                          minHeight: 12,
                          value: maxValue <= 0 ? 0 : value(row) / maxValue,
                          backgroundColor: PosColors.panelMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 112,
                      child: Text(valueLabel(row), textAlign: TextAlign.right),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RegionPanel extends StatelessWidget {
  const _RegionPanel({required this.regions, required this.copy});
  final List<Map<String, dynamic>> regions;
  final DirectOrderCopy copy;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            copy.ordersByRegion,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            copy.privacySuppressed,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 12),
          for (final row in regions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                row['district'] == 'suppressed'
                    ? Icons.privacy_tip_outlined
                    : Icons.location_on_outlined,
              ),
              title: Text(
                row['district'] == 'suppressed'
                    ? copy.privacySuppressed
                    : '${row['district'] ?? ''} ${row['ward'] ?? ''}',
              ),
              trailing: Text(
                '${_number(row['order_count']).toInt()}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
        ],
      ),
    ),
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : const [];
double _number(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(value?.toString() ?? '') ?? 0;
