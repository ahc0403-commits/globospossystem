import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../main.dart';
import '../../../widgets/error_toast.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final _einvoiceJobsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final result = await supabase
      .from('einvoice_jobs')
      .select('''
        id, ref_id, status, sid, error_classification, error_message,
        dispatch_attempts, request_einvoice_retry_count,
        dispatched_at, created_at, lookup_url,
        redinvoice_requested,
        orders ( id, tables ( table_number ) ),
        tax_entity ( tax_code )
      ''')
      .inFilter('status', ['failed_terminal', 'stale', 'dispatched_polling_disabled'])
      .order('created_at', ascending: false)
      .limit(100);
  return (result as List).map((e) => Map<String, dynamic>.from(e)).toList();
});

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
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
    final jobs = _filter == 'all'
        ? all
        : all.where((j) => j['status'] == _filter).toList();

    if (jobs.isEmpty) {
      return Center(
        child: Text(
          'No jobs',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary, fontSize: 14),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: jobs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _JobCard(
        job: jobs[i],
        onRetry: () {
          ref.invalidate(_einvoiceJobsProvider);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Job Card
// ---------------------------------------------------------------------------

class _JobCard extends StatefulWidget {
  const _JobCard({required this.job, required this.onRetry});
  final Map<String, dynamic> job;
  final VoidCallback onRetry;

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _isRetrying = false;

  String get _status => widget.job['status'] ?? '';
  bool get _isFailed => _status == 'failed_terminal' || _status == 'stale';
  bool get _isPendingPolling => _status == 'dispatched_polling_disabled';

  Color get _statusColor => switch (_status) {
    'failed_terminal' => AppColors.statusCancelled,
    'stale'           => AppColors.statusOccupied,
    _                 => AppColors.textSecondary,
  };

  Future<void> _retry() async {
    setState(() => _isRetrying = true);
    try {
      await supabase.from('einvoice_jobs').update({
        'status': 'pending',
        'dispatch_attempts': 0,
        'error_classification': null,
        'error_message': null,
        'request_einvoice_retry_count': 0,
        'request_einvoice_next_retry_at': null,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', widget.job['id']);
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

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy-MM-dd HH:mm').format(
      DateTime.parse(widget.job['created_at'].toString()).toLocal(),
    );
    final tableNum = widget.job['orders']?['tables']?['table_number'];
    final taxCode  = widget.job['tax_entity']?['tax_code'] ?? '—';
    final errClass = widget.job['error_classification'] ?? '';
    final errMsg   = widget.job['error_message'] ?? '';
    final lookupUrl = widget.job['lookup_url'];
    final refId    = (widget.job['ref_id'] ?? '').toString();

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
                  _status.toUpperCase().replaceAll('_', ' '),
                  style: GoogleFonts.notoSansKr(
                    color: _statusColor, fontSize: 10, fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_isPendingPolling) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.amber500.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.amber500),
                  ),
                  child: Text(
                    widget.job['redinvoice_requested'] == true ? 'RED INV' : 'BASIC',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.amber500, fontSize: 10, fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                date,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary, fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Info row
          Row(
            children: [
              if (tableNum != null) _infoChip(Icons.table_restaurant, 'T$tableNum'),
              const SizedBox(width: 8),
              _infoChip(Icons.business, taxCode),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  refId,
                  style: GoogleFonts.firaCode(
                    color: AppColors.textSecondary, fontSize: 10,
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
                color: _statusColor, fontSize: 12, fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (errMsg.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              errMsg.length > 120 ? '${errMsg.substring(0, 120)}…' : errMsg,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary, fontSize: 11,
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                FilledButton.icon(
                  onPressed: _isRetrying ? null : _retry,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: _isRetrying
                      ? const SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.replay, size: 14),
                  label: Text(
                    'Retry',
                    style: GoogleFonts.notoSansKr(
                      fontSize: 12, fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
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
            color: AppColors.textSecondary, fontSize: 11,
          ),
        ),
      ],
    );
  }
}
