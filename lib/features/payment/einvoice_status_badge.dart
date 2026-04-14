import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../main.dart';
import 'einvoice_provider.dart';

/// Small badge showing einvoice job status for a given order.
/// Shows: pending / dispatched / issued / failed — with WeTax portal link if available.
class EinvoiceStatusBadge extends ConsumerWidget {
  const EinvoiceStatusBadge({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobAsync = ref.watch(einvoiceJobStatusProvider(orderId));

    return jobAsync.when(
      data: (job) {
        if (job == null) return const SizedBox.shrink();
        return _BadgeRow(job: job);
      },
      loading: () => const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.amber500),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _BadgeRow extends StatelessWidget {
  const _BadgeRow({required this.job});
  final EinvoiceJobStatus job;

  Color get _color => switch (job.status) {
    'pending'                    => AppColors.textSecondary,
    'dispatched'                 => AppColors.amber500,
    'dispatched_polling_disabled'=> AppColors.amber500,
    'reported'                   => AppColors.statusAvailable,
    'issued_by_portal'           => AppColors.statusAvailable,
    'failed_terminal'            => AppColors.statusCancelled,
    'stale'                      => AppColors.statusOccupied,
    _                            => AppColors.textSecondary,
  };

  IconData get _icon => switch (job.status) {
    'pending'                    => Icons.hourglass_empty,
    'dispatched'                 => Icons.send,
    'dispatched_polling_disabled'=> Icons.send,
    'reported'                   => Icons.check_circle_outline,
    'issued_by_portal'           => Icons.check_circle,
    'failed_terminal'            => Icons.error_outline,
    'stale'                      => Icons.warning_amber,
    _                            => Icons.receipt_long,
  };

  String get _label => switch (job.status) {
    'pending'                    => 'Invoice: Queued',
    'dispatched'                 => 'Invoice: Sent',
    'dispatched_polling_disabled'=> 'Invoice: Sent',
    'reported'                   => 'Invoice: Reported',
    'issued_by_portal'           => job.redinvoiceRequested
                                      ? 'Red Invoice: Issued'
                                      : 'Invoice: Issued',
    'failed_terminal'            => 'Invoice: Failed',
    'stale'                      => 'Invoice: Stale',
    _                            => 'Invoice: Unknown',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _color.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 12, color: _color),
              const SizedBox(width: 4),
              Text(
                _label,
                style: GoogleFonts.notoSansKr(
                  color: _color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (job.lookupUrl != null && job.lookupUrl!.isNotEmpty) ...[
          const SizedBox(width: 6),
          InkWell(
            onTap: () => launchUrl(Uri.parse(job.lookupUrl!)),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.open_in_new, size: 11, color: AppColors.textSecondary),
                  const SizedBox(width: 3),
                  Text(
                    'WeTax',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
