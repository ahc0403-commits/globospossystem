import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../main.dart';
import '../../auth/auth_provider.dart';
import '../../../widgets/error_toast.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

class _EinvoiceOpsFlags {
  const _EinvoiceOpsFlags({
    required this.pollingEnabled,
    required this.dispatchEnabled,
  });

  final bool pollingEnabled;
  final bool dispatchEnabled;
}

final _einvoiceJobsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final result = await supabase
          .from('einvoice_jobs')
          .select('''
        id, ref_id, status, sid, error_classification, error_message,
        dispatch_attempts, request_einvoice_retry_count,
        dispatched_at, created_at, lookup_url,
        redinvoice_requested,
        orders ( id, restaurant_id, tables ( table_number ) ),
        tax_entity ( tax_code )
      ''')
          .inFilter('status', [
            'failed_terminal',
            'stale',
            'dispatched_polling_disabled',
          ])
          .order('created_at', ascending: false)
          .limit(100);
      return (result as List).map((e) => Map<String, dynamic>.from(e)).toList();
    });

final _einvoiceOpsFlagsProvider =
    FutureProvider.autoDispose<_EinvoiceOpsFlags?>((ref) async {
      try {
        final result = await supabase
            .from('system_config')
            .select('key, value')
            .inFilter('key', [
              'wetax_polling_enabled',
              'wetax_dispatch_enabled',
            ]);

        final rows = (result as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        final values = <String, String>{
          for (final row in rows)
            row['key'].toString(): row['value']?.toString() ?? '',
        };

        return _EinvoiceOpsFlags(
          pollingEnabled: _parseFlag(values['wetax_polling_enabled']),
          dispatchEnabled: _parseFlag(values['wetax_dispatch_enabled']),
        );
      } catch (_) {
        return null;
      }
    });

bool _parseFlag(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized == 'true' || normalized == '1' || normalized == 'yes';
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------

class EinvoiceTab extends ConsumerStatefulWidget {
  const EinvoiceTab({super.key});

  @override
  ConsumerState<EinvoiceTab> createState() => _EinvoiceTabState();
}

class _EinvoiceTabState extends ConsumerState<EinvoiceTab> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(_einvoiceJobsProvider);
    final flags = ref.watch(_einvoiceOpsFlagsProvider).valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        if (flags != null) _opsBanner(flags, jobsAsync.valueOrNull ?? const []),
        _filterBar(),
        const Divider(height: 1, color: AppColors.surface2),
        Expanded(
          child: jobsAsync.when(
            data: (jobs) => _jobList(jobs),
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            ),
            error: (e, _) => Center(
              child: Text(
                'Failed to load: $e',
                style: GoogleFonts.notoSansKr(color: AppColors.statusCancelled),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        children: [
          const Icon(Icons.receipt_long, color: AppColors.amber500, size: 22),
          const SizedBox(width: 8),
          Text(
            'E-Invoice Jobs',
            style: GoogleFonts.bebasNeue(
              color: AppColors.textPrimary,
              fontSize: 26,
              letterSpacing: 1,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(_einvoiceJobsProvider),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Wrap(
        spacing: 8,
        children: [
          _chip('all', 'All'),
          _chip('failed_terminal', 'Failed'),
          _chip('stale', 'Stale'),
          _chip('dispatched_polling_disabled', 'Pending Polling'),
          _chip('resolved', 'Resolved'),
        ],
      ),
    );
  }

  Widget _chip(String value, String label) {
    final selected = _filter == value;
    return FilterChip(
      label: Text(label, style: GoogleFonts.notoSansKr(fontSize: 12)),
      selected: selected,
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: AppColors.amber500.withValues(alpha: 0.2),
      checkmarkColor: AppColors.amber500,
      side: BorderSide(
        color: selected ? AppColors.amber500 : AppColors.surface2,
      ),
      backgroundColor: AppColors.surface1,
      labelStyle: GoogleFonts.notoSansKr(
        color: selected ? AppColors.amber500 : AppColors.textSecondary,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
      ),
    );
  }

  Widget _jobList(List<Map<String, dynamic>> all) {
    bool isResolved(Map<String, dynamic> job) =>
        (job['error_classification']?.toString() ?? '') == 'manual_resolved';

    final jobs = switch (_filter) {
      'all' => all.where((job) => !isResolved(job)).toList(),
      'resolved' => all.where(isResolved).toList(),
      _ =>
        all
            .where((job) => job['status'] == _filter && !isResolved(job))
            .toList(),
    };

    if (jobs.isEmpty) {
      return Center(
        child: Text(
          'No jobs',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: jobs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _JobCard(
        ref: ref,
        job: jobs[i],
        onRetry: () {
          ref.invalidate(_einvoiceJobsProvider);
        },
      ),
    );
  }

  Widget _opsBanner(_EinvoiceOpsFlags flags, List<Map<String, dynamic>> jobs) {
    final pendingPollingCount = jobs
        .where((job) => job['status'] == 'dispatched_polling_disabled')
        .length;
    final banners = <Widget>[];

    if (!flags.dispatchEnabled) {
      banners.add(
        _bannerCard(
          color: AppColors.statusCancelled,
          icon: Icons.pause_circle_outline,
          title: 'Dispatch Disabled',
          body:
              'New e-invoice jobs stay queued until `wetax_dispatch_enabled` is turned back on.',
        ),
      );
    }

    if (!flags.pollingEnabled) {
      final detail = pendingPollingCount > 0
          ? '$pendingPollingCount sent jobs are waiting for WT06 follow-up.'
          : 'Newly sent jobs will remain in Pending Polling.';
      banners.add(
        _bannerCard(
          color: AppColors.statusOccupied,
          icon: Icons.sync_disabled,
          title: 'Polling Disabled',
          body:
              '$detail Turn on `wetax_polling_enabled` when vendor polling is ready again.',
        ),
      );
    }

    if (banners.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        children:
            banners
                .expand((banner) => [banner, const SizedBox(height: 8)])
                .toList()
              ..removeLast(),
      ),
    );
  }

  Widget _bannerCard({
    required Color color,
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.bebasNeue(
                    color: color,
                    fontSize: 20,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Job Card
// ---------------------------------------------------------------------------

class _JobCard extends StatefulWidget {
  const _JobCard({required this.ref, required this.job, required this.onRetry});
  final WidgetRef ref;
  final Map<String, dynamic> job;
  final VoidCallback onRetry;

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _isRetrying = false;
  bool _isResolving = false;

  String get _status => widget.job['status'] ?? '';
  bool get _isFailed => _status == 'failed_terminal' || _status == 'stale';
  bool get _isResolved =>
      (widget.job['error_classification']?.toString() ?? '') ==
      'manual_resolved';
  bool get _isPendingPolling => _status == 'dispatched_polling_disabled';

  Color get _statusColor {
    if (_isResolved) return AppColors.statusAvailable;

    return switch (_status) {
      'failed_terminal' => AppColors.statusCancelled,
      'stale' => AppColors.statusOccupied,
      'dispatched_polling_disabled' => AppColors.amber500,
      _ => AppColors.textSecondary,
    };
  }

  String get _statusLabel =>
      _isResolved ? 'RESOLVED' : _status.toUpperCase().replaceAll('_', ' ');

  Future<String> _requireStoreId() async {
    final orderRaw = widget.job['orders'];
    final storeId = orderRaw is Map<String, dynamic>
        ? orderRaw['restaurant_id']?.toString()
        : null;
    final auth = widget.ref.read(authProvider);

    if (storeId == null || storeId.isEmpty) {
      throw Exception('Missing store for this job.');
    }

    if (auth.role != 'super_admin' && auth.storeId != storeId) {
      throw Exception('Switch to the target store before changing this job.');
    }

    return storeId;
  }

  Future<void> _retry() async {
    setState(() => _isRetrying = true);
    try {
      final storeId = await _requireStoreId();

      await supabase.rpc(
        'admin_retry_einvoice_job',
        params: {'p_job_id': widget.job['id'], 'p_store_id': storeId},
      );
      if (mounted) {
        showSuccessToast(context, 'Job queued for retry');
        widget.onRetry();
      }
    } catch (e) {
      if (mounted) showErrorToast(context, 'Retry failed: $e');
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _markResolved() async {
    setState(() => _isResolving = true);
    try {
      final storeId = await _requireStoreId();

      await supabase.rpc(
        'admin_mark_resolved_einvoice_job',
        params: {'p_job_id': widget.job['id'], 'p_store_id': storeId},
      );
      if (mounted) {
        showSuccessToast(context, 'Job marked resolved');
        widget.onRetry();
      }
    } catch (e) {
      if (mounted) showErrorToast(context, 'Resolve failed: $e');
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = DateFormat(
      'yyyy-MM-dd HH:mm',
    ).format(DateTime.parse(widget.job['created_at'].toString()).toLocal());
    final tableNum = widget.job['orders']?['tables']?['table_number'];
    final taxCode = widget.job['tax_entity']?['tax_code'] ?? '—';
    final errClass = widget.job['error_classification'] ?? '';
    final errMsg = widget.job['error_message'] ?? '';
    final lookupUrl = widget.job['lookup_url'];
    final refId = (widget.job['ref_id'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _statusColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _statusColor),
                ),
                child: Text(
                  _statusLabel,
                  style: GoogleFonts.notoSansKr(
                    color: _statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_isPendingPolling) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.amber500.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.amber500),
                  ),
                  child: Text(
                    widget.job['redinvoice_requested'] == true
                        ? 'RED INV'
                        : 'BASIC',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.amber500,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              if (_isResolved) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.statusAvailable.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.statusAvailable),
                  ),
                  child: Text(
                    'NO ACTION',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.statusAvailable,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                date,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Info row
          Row(
            children: [
              if (tableNum != null)
                _infoChip(Icons.table_restaurant, 'T$tableNum'),
              const SizedBox(width: 8),
              _infoChip(Icons.business, taxCode),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  refId,
                  style: GoogleFonts.firaCode(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (errClass.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              errClass,
              style: GoogleFonts.notoSansKr(
                color: _statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (errMsg.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              errMsg.length > 120 ? '${errMsg.substring(0, 120)}…' : errMsg,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 10),
          // Actions
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (lookupUrl != null && lookupUrl.toString().isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(lookupUrl.toString())),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.surface2),
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: Text(
                    'WeTax Portal',
                    style: GoogleFonts.notoSansKr(fontSize: 12),
                  ),
                ),
              const SizedBox(width: 8),
              if (_isFailed)
                OutlinedButton.icon(
                  onPressed: _isResolving || _isResolved ? null : _markResolved,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusAvailable,
                    side: const BorderSide(color: AppColors.statusAvailable),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: _isResolving
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: AppColors.statusAvailable,
                          ),
                        )
                      : const Icon(Icons.check_circle_outline, size: 14),
                  label: Text(
                    'Mark Resolved',
                    style: GoogleFonts.notoSansKr(fontSize: 12),
                  ),
                ),
              if (_isFailed && !_isResolved) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isRetrying ? null : _retry,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: _isRetrying
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.replay, size: 14),
                  label: Text(
                    'Retry',
                    style: GoogleFonts.notoSansKr(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppColors.textSecondary),
        const SizedBox(width: 3),
        Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
