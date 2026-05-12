import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/utils/permission_utils.dart';
import '../../core/utils/role_routes.dart';
import '../../core/utils/time_utils.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import '../../core/services/qc_service.dart';
import 'qc_provider.dart';

class QcReviewScreen extends ConsumerStatefulWidget {
  const QcReviewScreen({super.key});

  @override
  ConsumerState<QcReviewScreen> createState() => _QcReviewScreenState();
}

class _QcReviewScreenState extends ConsumerState<QcReviewScreen> {
  String? _initializedRestaurantId;
  bool _didHandleUnauthorized = false;
  String _filter = 'pending';
  String _sortMode = 'pending_first';
  String _domainFilter = 'all';
  String _photoFilter = 'all';
  String _svRequirementFilter = 'required';
  String _issueSeverityFilter = 'all';
  String _issueSubmissionFilter = 'all';
  DateTime _weekStart = _startOfWeek(TimeUtils.nowVietnam());
  final Set<String> _selectedCheckIds = <String>{};
  String? _selectedIssueId;

  static DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  Future<void> _initialize(String storeId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(storeId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: _weekStart);
    await ref.read(qcIssueQueueProvider.notifier).load(storeId);
  }

  Future<void> _loadWeek(String storeId, DateTime start) async {
    setState(() => _weekStart = start);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: start);
  }

  void _toggleCheckSelection(String checkId, bool selected) {
    setState(() {
      if (selected) {
        _selectedCheckIds.add(checkId);
      } else {
        _selectedCheckIds.remove(checkId);
      }
    });
  }

  void _toggleAllVisible(List<Map<String, dynamic>> checks, bool selected) {
    setState(() {
      final ids = checks
          .map((check) => check['id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList();
      if (selected) {
        _selectedCheckIds.addAll(ids);
      } else {
        _selectedCheckIds.removeAll(ids);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final canReview = PermissionUtils.canDoQcVisitReview(
      auth.role,
      auth.extraPermissions,
    );
    final checkState = ref.watch(qcCheckProvider);
    final issueQueueState = ref.watch(qcIssueQueueProvider);

    if (!canReview) {
      if (!_didHandleUnauthorized) {
        _didHandleUnauthorized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showErrorToast(context, context.l10n.qscNoReviewPermission);
          context.go(homeRouteForRole(auth.role));
        });
      }
      return Scaffold(
        backgroundColor: PosColors.canvas,
        body: Center(
          child: Text(
            'No permission to review QSC inspections.',
            style: GoogleFonts.notoSansKr(color: PosColors.text, fontSize: 14),
          ),
        ),
      );
    }

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initialize(storeId));
    }

    final pendingCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'pending')
        .length;
    final reviewedCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'reviewed')
        .length;
    final rejectedCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'rejected')
        .length;

    final domainOptions = <String>{
      'all',
      ...checkState.checks.map((check) {
        final template = check['qc_templates'] as Map<String, dynamic>?;
        return template?['qsc_domain']?.toString() ?? 'quality';
      }),
    }.toList();

    final filteredChecks = checkState.checks.where((check) {
      final status = _effectiveSvStatus(check);
      final template = check['qc_templates'] as Map<String, dynamic>?;
      final domain = template?['qsc_domain']?.toString() ?? 'quality';
      final isSvRequired = template?['is_sv_required'] == true;
      final photoRequiredCount = _readInt(check['photo_required_count']) ?? 0;
      final photoUploadedCount = _readInt(check['photo_uploaded_count']) ?? 0;

      final matchesStatus = switch (_filter) {
        'pending' => status == 'pending',
        'reviewed' => status == 'reviewed',
        'rejected' => status == 'rejected',
        'all' => true,
        _ => true,
      };
      final matchesDomain = _domainFilter == 'all' || domain == _domainFilter;
      final matchesPhoto = switch (_photoFilter) {
        'missing' =>
          photoRequiredCount > 0 && photoUploadedCount < photoRequiredCount,
        'complete' =>
          photoRequiredCount > 0 && photoUploadedCount >= photoRequiredCount,
        'not_required' => photoRequiredCount == 0,
        _ => true,
      };
      final matchesSvRequirement = switch (_svRequirementFilter) {
        'required' => isSvRequired,
        'not_required' => !isSvRequired,
        _ => true,
      };
      return matchesStatus &&
          matchesDomain &&
          matchesPhoto &&
          matchesSvRequirement;
    }).toList();

    filteredChecks.sort((a, b) {
      switch (_sortMode) {
        case 'risk_first':
          final gradeOrder = {'risk': 0, 'caution': 1, 'good': 2};
          final aGrade = gradeOrder[a['grade']?.toString()] ?? 9;
          final bGrade = gradeOrder[b['grade']?.toString()] ?? 9;
          if (aGrade != bGrade) return aGrade.compareTo(bGrade);
          break;
        case 'date_desc':
          final aDate = a['check_date']?.toString() ?? '';
          final bDate = b['check_date']?.toString() ?? '';
          final dateCompare = bDate.compareTo(aDate);
          if (dateCompare != 0) return dateCompare;
          break;
        case 'pending_first':
        default:
          final aPending = _effectiveSvStatus(a) == 'pending' ? 0 : 1;
          final bPending = _effectiveSvStatus(b) == 'pending' ? 0 : 1;
          if (aPending != bPending) return aPending.compareTo(bPending);
          final aDate = a['check_date']?.toString() ?? '';
          final bDate = b['check_date']?.toString() ?? '';
          final dateCompare = bDate.compareTo(aDate);
          if (dateCompare != 0) return dateCompare;
      }
      final aText =
          (a['qc_templates'] as Map<String, dynamic>?)?['criteria_text']
              ?.toString() ??
          '';
      final bText =
          (b['qc_templates'] as Map<String, dynamic>?)?['criteria_text']
              ?.toString() ??
          '';
      return aText.compareTo(bText);
    });

    final visibleIds = filteredChecks
        .map((check) => check['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();
    final selectedVisibleCount = visibleIds
        .where((id) => _selectedCheckIds.contains(id))
        .length;
    final allVisibleSelected =
        visibleIds.isNotEmpty && selectedVisibleCount == visibleIds.length;

    final groupedByDate = <String, List<Map<String, dynamic>>>{};
    for (final check in filteredChecks) {
      final date = check['check_date']?.toString() ?? '-';
      groupedByDate.putIfAbsent(date, () => []).add(check);
    }

    final queueIssues = issueQueueState.issues.where((issue) {
      final severity = issue['severity']?.toString() ?? 'info';
      final domain = issue['qsc_domain']?.toString() ?? 'quality';
      final photoStatus = issue['photo_status']?.toString() ?? 'na';
      final submissionStatus =
          issue['submission_status']?.toString() ?? 'pending';

      final matchesSeverity =
          _issueSeverityFilter == 'all' || severity == _issueSeverityFilter;
      final matchesDomain =
          _domainFilter == 'all' || domain == _domainFilter;
      final matchesPhoto = switch (_photoFilter) {
        'missing' => photoStatus == 'missing' || photoStatus == 'partial',
        'complete' => photoStatus == 'complete',
        'not_required' => photoStatus == 'na',
        _ => true,
      };
      final matchesSubmission =
          _issueSubmissionFilter == 'all' ||
          submissionStatus == _issueSubmissionFilter;

      return matchesSeverity &&
          matchesDomain &&
          matchesPhoto &&
          matchesSubmission;
    }).toList()
      ..sort((a, b) {
        final aSeverity = _issueSeverityRank(a['severity']?.toString());
        final bSeverity = _issueSeverityRank(b['severity']?.toString());
        if (aSeverity != bSeverity) return aSeverity.compareTo(bSeverity);
        final aDate = a['check_date']?.toString() ?? '';
        final bDate = b['check_date']?.toString() ?? '';
        final dateCompare = bDate.compareTo(aDate);
        if (dateCompare != 0) return dateCompare;
        final aCreated = a['created_at']?.toString() ?? '';
        final bCreated = b['created_at']?.toString() ?? '';
        return bCreated.compareTo(aCreated);
      });

    Map<String, dynamic>? selectedIssue;
    if (queueIssues.isNotEmpty) {
      for (final issue in queueIssues) {
        if (issue['check_id']?.toString() == _selectedIssueId) {
          selectedIssue = issue;
          break;
        }
      }
      selectedIssue ??= queueIssues.first;
    }

    return Scaffold(
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        backgroundColor: PosColors.canvas,
        elevation: 0,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppNavBar()),
          ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'QSC Review',
              style: GoogleFonts.notoSansKr(
                color: PosColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              _weekLabel(),
              style: GoogleFonts.notoSansKr(
                color: PosColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: checkState.isLoading
          ? const Center(
              child: CircularProgressIndicator(color: PosColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.subtract(const Duration(days: 7)),
                            ),
                      icon: const Icon(
                        Icons.chevron_left,
                        color: PosColors.text,
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          _weekLabel(),
                          style: GoogleFonts.notoSansKr(
                            color: PosColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.add(const Duration(days: 7)),
                            ),
                      icon: const Icon(
                        Icons.chevron_right,
                        color: PosColors.text,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _summaryChip(
                      context.l10n.qscPendingCount(pendingCount),
                      PosColors.accent,
                    ),
                    _summaryChip(
                      context.l10n.qscReviewedCount(reviewedCount),
                      PosColors.success,
                    ),
                    _summaryChip(
                      context.l10n.qscRejectedCount(rejectedCount),
                      PosColors.danger,
                    ),
                    _summaryChip(
                      context.l10n.qscSelectedCount(_selectedCheckIds.length),
                      PosColors.info,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: PosColors.panelStrong,
                    borderRadius: ToastRadiusTokens.xs,
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Issue Queue',
                                  style: GoogleFonts.notoSansKr(
                                    color: PosColors.text,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Read-only exception queue from the tracked QSC issue view.',
                                  style: GoogleFonts.notoSansKr(
                                    color: PosColors.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed: storeId == null
                                ? null
                                : () => ref
                                      .read(qcIssueQueueProvider.notifier)
                                      .load(storeId),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh Issue Queue'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _issueSeverityFilter,
                              decoration: const InputDecoration(
                                labelText: 'Severity',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'all',
                                  child: Text('All severities'),
                                ),
                                DropdownMenuItem(
                                  value: 'critical',
                                  child: Text('Critical'),
                                ),
                                DropdownMenuItem(
                                  value: 'high',
                                  child: Text('High'),
                                ),
                                DropdownMenuItem(
                                  value: 'medium',
                                  child: Text('Medium'),
                                ),
                                DropdownMenuItem(
                                  value: 'low',
                                  child: Text('Low'),
                                ),
                                DropdownMenuItem(
                                  value: 'info',
                                  child: Text('Info'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => _issueSeverityFilter = value);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _issueSubmissionFilter,
                              decoration: const InputDecoration(
                                labelText: 'Submission',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'all',
                                  child: Text('All submissions'),
                                ),
                                DropdownMenuItem(
                                  value: 'pending',
                                  child: Text('Pending'),
                                ),
                                DropdownMenuItem(
                                  value: 'overdue',
                                  child: Text('Overdue'),
                                ),
                                DropdownMenuItem(
                                  value: 'submitted',
                                  child: Text('Submitted'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => _issueSubmissionFilter = value);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (issueQueueState.error != null) ...[
                        Text(
                          issueQueueState.error!,
                          style: GoogleFonts.notoSansKr(
                            color: PosColors.danger,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (issueQueueState.isLoading && issueQueueState.issues.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: CircularProgressIndicator(
                              color: PosColors.accent,
                            ),
                          ),
                        )
                      else if (queueIssues.isEmpty)
                        Text(
                          'No issue queue items match the current filters.',
                          style: GoogleFonts.notoSansKr(
                            color: PosColors.textMuted,
                          ),
                        )
                      else
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final vertical = constraints.maxWidth < 960;
                            final listPane = _issueQueueList(queueIssues);
                            final detailPane = _issueQueueDetail(selectedIssue);

                            if (vertical) {
                              return Column(
                                children: [
                                  SizedBox(height: 260, child: listPane),
                                  const SizedBox(height: 12),
                                  detailPane,
                                ],
                              );
                            }

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 5, child: SizedBox(height: 360, child: listPane)),
                                const SizedBox(width: 12),
                                Expanded(flex: 4, child: detailPane),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _domainFilter,
                        decoration: InputDecoration(
                          labelText: context.l10n.qscDomain,
                        ),
                        items: domainOptions
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(switch (value) {
                                  'quality' => context.l10n.qscDomainQuality,
                                  'service' => context.l10n.qscDomainService,
                                  'cleanliness' =>
                                    context.l10n.qscDomainCleanliness,
                                  _ => context.l10n.all,
                                }),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _domainFilter = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _photoFilter,
                        decoration: InputDecoration(
                          labelText: context.l10n.qscPhotoStatus,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text(context.l10n.all),
                          ),
                          DropdownMenuItem(
                            value: 'missing',
                            child: Text(context.l10n.qscMissingPhoto),
                          ),
                          DropdownMenuItem(
                            value: 'complete',
                            child: Text(context.l10n.qscPhotoComplete),
                          ),
                          DropdownMenuItem(
                            value: 'not_required',
                            child: Text(context.l10n.qscPhotoNa),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _photoFilter = value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _svRequirementFilter,
                        decoration: InputDecoration(
                          labelText: context.l10n.qscSvRequirement,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'required',
                            child: Text(context.l10n.qscSvRequired),
                          ),
                          DropdownMenuItem(
                            value: 'not_required',
                            child: Text(context.l10n.qscSvNotRequired),
                          ),
                          DropdownMenuItem(
                            value: 'all',
                            child: Text(context.l10n.all),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _svRequirementFilter = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Container()),
                  ],
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('pending', context.l10n.qscPending),
                      const SizedBox(width: 8),
                      _filterChip('reviewed', context.l10n.qscReviewed),
                      const SizedBox(width: 8),
                      _filterChip('rejected', context.l10n.qscRejected),
                      const SizedBox(width: 8),
                      _filterChip('all', context.l10n.all),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _sortMode,
                        decoration: InputDecoration(
                          labelText: context.l10n.qscSort,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'pending_first',
                            child: Text(context.l10n.qscPendingFirst),
                          ),
                          DropdownMenuItem(
                            value: 'date_desc',
                            child: Text(context.l10n.qscNewestFirst),
                          ),
                          DropdownMenuItem(
                            value: 'risk_first',
                            child: Text(context.l10n.qscRiskFirst),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _sortMode = value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (filteredChecks.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: PosColors.panelStrong,
                      borderRadius: ToastRadiusTokens.xs,
                      border: Border.all(color: PosColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: allVisibleSelected,
                              onChanged: (value) => _toggleAllVisible(
                                filteredChecks,
                                value ?? false,
                              ),
                              activeColor: PosColors.accent,
                            ),
                            Expanded(
                              child: Text(
                                'Select visible inspections',
                                style: GoogleFonts.notoSansKr(
                                  color: PosColors.text,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '$selectedVisibleCount / ${visibleIds.length}',
                              style: GoogleFonts.notoSansKr(
                                color: PosColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _selectedCheckIds.isEmpty || storeId == null
                                    ? null
                                    : () => _openBulkReviewSheet(
                                        context: context,
                                        auth: auth,
                                        status: 'rejected',
                                      ),
                                icon: const Icon(Icons.error_outline),
                                label: Text(context.l10n.qscBulkFollowUp),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed:
                                    _selectedCheckIds.isEmpty || storeId == null
                                    ? null
                                    : () => _openBulkReviewSheet(
                                        context: context,
                                        auth: auth,
                                        status: 'reviewed',
                                      ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: PosColors.accent,
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.verified_outlined),
                                label: Text(context.l10n.qscBulkReview),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (filteredChecks.isNotEmpty) const SizedBox(height: 12),
                if (checkState.error != null) ...[
                  Text(
                    checkState.error!,
                    style: GoogleFonts.notoSansKr(
                      color: PosColors.danger,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (filteredChecks.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: PosColors.panelStrong,
                      borderRadius: ToastRadiusTokens.xs,
                      border: Border.all(color: PosColors.border),
                    ),
                    child: Text(
                      'No QSC reviews found for this filter.',
                      style: GoogleFonts.notoSansKr(color: PosColors.textMuted),
                    ),
                  ),
                for (final entry in groupedByDate.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Text(
                      entry.key,
                      style: GoogleFonts.notoSansKr(
                        color: PosColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ...entry.value.map((check) {
                    final checkId = check['id']?.toString() ?? '';
                    return _reviewCard(
                      context,
                      auth,
                      check,
                      isSelected: _selectedCheckIds.contains(checkId),
                      onSelected: checkId.isEmpty
                          ? null
                          : (selected) =>
                                _toggleCheckSelection(checkId, selected),
                    );
                  }),
                ],
                const SizedBox(height: 16),
              ],
            ),
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _filter == value;
    return InkWell(
      onTap: () => setState(() => _filter = value),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? PosColors.accent.withValues(alpha: 0.16)
              : PosColors.panelStrong,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? PosColors.accent : PosColors.border,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: selected ? PosColors.accent : PosColors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _reviewCard(
    BuildContext context,
    dynamic auth,
    Map<String, dynamic> check, {
    required bool isSelected,
    required ValueChanged<bool>? onSelected,
  }) {
    final template = check['qc_templates'] as Map<String, dynamic>?;
    final effectiveStatus = _effectiveSvStatus(check);
    final canReview = effectiveStatus != 'not_required';
    final photoUrl = check['evidence_photo_url']?.toString();
    final uploadedPhotoCount = _readInt(check['photo_uploaded_count']) ?? 0;
    final scoreText = check['sv_score']?.toString();
    final note = check['note']?.toString();
    final svNote = check['sv_note']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.panelStrong,
        borderRadius: ToastRadiusTokens.xs,
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: onSelected == null
                    ? null
                    : (value) => onSelected(value ?? false),
                activeColor: PosColors.accent,
              ),
              Expanded(
                child: Text(
                  template?['criteria_text']?.toString() ?? '-',
                  style: GoogleFonts.notoSansKr(
                    color: PosColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              _statusChip(
                _svStatusLabel(effectiveStatus),
                _svStatusColor(effectiveStatus),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip(
                (template?['category']?.toString() ??
                    context.l10n.qcCategoryOther),
                PosColors.textMuted,
              ),
              _statusChip(
                (check['result']?.toString() ?? '-').toUpperCase(),
                _resultColor(check['result']?.toString()),
              ),
              if (check['grade']?.toString().isNotEmpty == true)
                _statusChip(
                  check['grade'].toString().toUpperCase(),
                  _gradeColor(check['grade']?.toString()),
                ),
              _statusChip(
                'Photo ${_readInt(check['photo_uploaded_count']) ?? 0}/${_readInt(check['photo_required_count']) ?? 0}',
                PosColors.info,
              ),
            ],
          ),
          if (photoUrl != null && photoUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _openPhotoGallery(check),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  photoUrl,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            if (uploadedPhotoCount > 1) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _openPhotoGallery(check),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(context.l10n.qscViewAllPhotos(uploadedPhotoCount)),
              ),
            ],
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              context.l10n.qscStaffNote,
              style: GoogleFonts.notoSansKr(
                color: PosColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(note, style: GoogleFonts.notoSansKr(color: PosColors.text)),
          ],
          if (scoreText != null && scoreText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              context.l10n.qscSvScoreValue(scoreText),
              style: GoogleFonts.notoSansKr(
                color: PosColors.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (svNote != null && svNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.qscSvNote,
              style: GoogleFonts.notoSansKr(
                color: PosColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(svNote, style: GoogleFonts.notoSansKr(color: PosColors.text)),
          ],
          if (canReview) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openReviewSheet(
                      context: context,
                      auth: auth,
                      check: check,
                      status: 'rejected',
                    ),
                    icon: const Icon(Icons.error_outline),
                    label: Text(context.l10n.qscNeedsFollowUp),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _openReviewSheet(
                      context: context,
                      auth: auth,
                      check: check,
                      status: 'reviewed',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: PosColors.accent,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(context.l10n.qscMarkReviewed),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openBulkReviewSheet({
    required BuildContext context,
    required dynamic auth,
    required String status,
  }) async {
    final scoreController = TextEditingController();
    final noteController = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PosColors.panelStrong,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status == 'reviewed'
                    ? 'Bulk Mark Reviewed'
                    : 'Bulk Needs Follow-up',
                style: GoogleFonts.notoSansKr(
                  color: PosColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_selectedCheckIds.length} inspections selected',
                style: GoogleFonts.notoSansKr(
                  color: PosColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: scoreController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: GoogleFonts.notoSansKr(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvScore),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteController,
                minLines: 2,
                maxLines: 4,
                style: GoogleFonts.notoSansKr(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvNote),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final storeId = auth.storeId;
                    if (storeId == null || _selectedCheckIds.isEmpty) return;
                    try {
                      await ref
                          .read(qcCheckProvider.notifier)
                          .submitVisitReview(
                            storeId: storeId,
                            checkIds: _selectedCheckIds.toList(),
                            svReviewStatus: status,
                            svScore: double.tryParse(
                              scoreController.text.trim(),
                            ),
                            svNote: noteController.text.trim().isEmpty
                                ? null
                                : noteController.text.trim(),
                            visitSessionId: const Uuid().v4(),
                            reviewedAt: DateTime.now(),
                            reviewedBy: auth.user?.id,
                          );
                      if (!context.mounted) return;
                      setState(() => _selectedCheckIds.clear());
                      Navigator.of(context).pop();
                      showSuccessToast(
                        context,
                        context.l10n.qscBulkReviewSaved,
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      showErrorToast(context, e.toString());
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(context.l10n.qscSaveBulkReview),
                ),
              ),
            ],
          ),
        );
      },
    );

    scoreController.dispose();
    noteController.dispose();
  }

  Future<void> _openReviewSheet({
    required BuildContext context,
    required dynamic auth,
    required Map<String, dynamic> check,
    required String status,
  }) async {
    final scoreController = TextEditingController(
      text: check['sv_score']?.toString() ?? '',
    );
    final noteController = TextEditingController(
      text: check['sv_note']?.toString() ?? '',
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PosColors.panelStrong,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status == 'reviewed'
                    ? context.l10n.qscMarkReviewed
                    : context.l10n.qscNeedsFollowUp,
                style: GoogleFonts.notoSansKr(
                  color: PosColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: scoreController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: GoogleFonts.notoSansKr(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvScore),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteController,
                minLines: 2,
                maxLines: 4,
                style: GoogleFonts.notoSansKr(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvNote),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final storeId = auth.storeId;
                    final checkId = check['id']?.toString();
                    if (storeId == null || checkId == null || checkId.isEmpty) {
                      return;
                    }
                    try {
                      await ref
                          .read(qcCheckProvider.notifier)
                          .submitVisitReview(
                            storeId: storeId,
                            checkIds: [checkId],
                            svReviewStatus: status,
                            svScore: double.tryParse(
                              scoreController.text.trim(),
                            ),
                            svNote: noteController.text.trim().isEmpty
                                ? null
                                : noteController.text.trim(),
                            visitSessionId: const Uuid().v4(),
                            reviewedAt: DateTime.now(),
                            reviewedBy: auth.user?.id,
                          );
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      showSuccessToast(context, context.l10n.qscReviewSaved);
                    } catch (e) {
                      if (!context.mounted) return;
                      showErrorToast(context, e.toString());
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(context.l10n.qscSaveReview),
                ),
              ),
            ],
          ),
        );
      },
    );

    scoreController.dispose();
    noteController.dispose();
  }

  Widget _issueQueueList(List<Map<String, dynamic>> issues) {
    return ListView.separated(
      itemCount: issues.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final issue = issues[index];
        final checkId = issue['check_id']?.toString() ?? '';
        final selected =
            (checkId.isNotEmpty && checkId == _selectedIssueId) ||
            (_selectedIssueId == null && index == 0);
        final severity = issue['severity']?.toString();

        return InkWell(
          onTap: () => setState(() => _selectedIssueId = checkId),
          borderRadius: ToastRadiusTokens.xs,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? PosColors.accent.withValues(alpha: 0.10)
                  : PosColors.canvas,
              borderRadius: ToastRadiusTokens.xs,
              border: Border.all(
                color: selected ? PosColors.accent : PosColors.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        issue['criteria_text']?.toString() ?? '-',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.notoSansKr(
                          color: PosColors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(
                      (severity ?? 'info').toUpperCase(),
                      _issueSeverityColor(severity),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statusChip(
                      issue['category']?.toString() ?? 'Other',
                      PosColors.textMuted,
                    ),
                    _statusChip(
                      issue['photo_status']?.toString() ?? 'na',
                      PosColors.info,
                    ),
                    _statusChip(
                      issue['submission_status']?.toString() ?? 'pending',
                      PosColors.accent,
                    ),
                    _statusChip(
                      issue['sv_review_status']?.toString() ?? 'pending',
                      _svStatusColor(issue['sv_review_status']?.toString() ?? 'pending'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${issue['store_name'] ?? '-'} · ${issue['check_date'] ?? '-'}',
                  style: GoogleFonts.notoSansKr(
                    color: PosColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _issueQueueDetail(Map<String, dynamic>? issue) {
    if (issue == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: PosColors.canvas,
          borderRadius: ToastRadiusTokens.xs,
          border: Border.all(color: PosColors.border),
        ),
        child: Text(
          'Queue Detail appears when you select an issue.',
          style: GoogleFonts.notoSansKr(color: PosColors.textMuted),
        ),
      );
    }

    final photoUrl = issue['evidence_photo_url']?.toString();
    final severity = issue['severity']?.toString();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.canvas,
        borderRadius: ToastRadiusTokens.xs,
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Queue Detail',
                  style: GoogleFonts.notoSansKr(
                    color: PosColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _statusChip(
                (severity ?? 'info').toUpperCase(),
                _issueSeverityColor(severity),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            issue['criteria_text']?.toString() ?? '-',
            style: GoogleFonts.notoSansKr(
              color: PosColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          _issueField('Store', issue['store_name']?.toString() ?? '-'),
          _issueField('Domain', issue['qsc_domain']?.toString() ?? '-'),
          _issueField('Check Date', issue['check_date']?.toString() ?? '-'),
          _issueField('Result', issue['result']?.toString() ?? '-'),
          _issueField(
            'Follow-up Status',
            issue['followup_status']?.toString() ?? '-',
          ),
          _issueField(
            'Submitted At',
            issue['submitted_at']?.toString() ?? 'Not submitted',
          ),
          _issueField('Score / Grade', _scoreGradeText(issue)),
          _issueField(
            'Evidence',
            photoUrl != null && photoUrl.isNotEmpty
                ? 'Photo available'
                : 'Photo not attached',
          ),
          if (issue['note']?.toString().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              'Note',
              style: GoogleFonts.notoSansKr(
                color: PosColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              issue['note'].toString(),
              style: GoogleFonts.notoSansKr(color: PosColors.text),
            ),
          ],
        ],
      ),
    );
  }

  Widget _issueField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: GoogleFonts.notoSansKr(
                color: PosColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.notoSansKr(color: PosColors.text),
            ),
          ),
        ],
      ),
    );
  }

  String _weekLabel() {
    final end = _weekStart.add(const Duration(days: 6));
    return '${DateFormat('MM/dd').format(_weekStart)} - ${DateFormat('MM/dd').format(end)}';
  }

  String _effectiveSvStatus(Map<String, dynamic> check) {
    final template = check['qc_templates'] as Map<String, dynamic>?;
    final isRequired = template?['is_sv_required'] == true;
    if (!isRequired) return 'not_required';
    final status = check['sv_review_status']?.toString();
    if (status == null || status.isEmpty) return 'pending';
    return status;
  }

  String _svStatusLabel(String status) {
    switch (status) {
      case 'reviewed':
        return 'SV Reviewed';
      case 'rejected':
        return 'SV Rejected';
      case 'not_required':
        return 'SV N/A';
      case 'pending':
      default:
        return 'SV Pending';
    }
  }

  Color _svStatusColor(String status) {
    switch (status) {
      case 'reviewed':
        return PosColors.success;
      case 'rejected':
        return PosColors.danger;
      case 'not_required':
        return PosColors.textMuted;
      case 'pending':
      default:
        return PosColors.accent;
    }
  }

  Color _resultColor(String? result) {
    switch (result) {
      case 'pass':
        return PosColors.success;
      case 'fail':
        return PosColors.danger;
      case 'na':
      default:
        return PosColors.textMuted;
    }
  }

  Color _gradeColor(String? grade) {
    switch (grade) {
      case 'good':
        return PosColors.success;
      case 'caution':
        return PosColors.accent;
      case 'risk':
        return PosColors.danger;
      default:
        return PosColors.textMuted;
    }
  }

  int _issueSeverityRank(String? severity) {
    switch (severity) {
      case 'critical':
        return 0;
      case 'high':
        return 1;
      case 'medium':
        return 2;
      case 'low':
        return 3;
      case 'info':
      default:
        return 4;
    }
  }

  Color _issueSeverityColor(String? severity) {
    switch (severity) {
      case 'critical':
        return PosColors.danger;
      case 'high':
        return Colors.deepOrangeAccent;
      case 'medium':
        return PosColors.accent;
      case 'low':
        return PosColors.info;
      case 'info':
      default:
        return PosColors.textMuted;
    }
  }

  String _scoreGradeText(Map<String, dynamic> issue) {
    final score = issue['score']?.toString();
    final grade = issue['grade']?.toString();
    if ((score == null || score.isEmpty) && (grade == null || grade.isEmpty)) {
      return '-';
    }
    if (score != null &&
        score.isNotEmpty &&
        grade != null &&
        grade.isNotEmpty) {
      return '$score / ${grade.toUpperCase()}';
    }
    return score?.isNotEmpty == true ? score! : grade!.toUpperCase();
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }

  Widget _statusChip(String label, Color color) {
    return ToastStatusBadge(label: label, color: color);
  }

  Widget _summaryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: ToastRadiusTokens.xs,
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _showImageDialog(String path) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.network(path, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openPhotoGallery(Map<String, dynamic> check) async {
    final checkId = check['id']?.toString();
    if (checkId == null || checkId.isEmpty) {
      final fallback = check['evidence_photo_url']?.toString();
      if (fallback != null && fallback.isNotEmpty) {
        await _showImageDialog(fallback);
      }
      return;
    }

    final photosFuture = qcService.fetchCheckPhotos(
      checkId: checkId,
      fallbackPhotoUrl: check['evidence_photo_url']?.toString(),
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        final pageController = PageController();
        var currentIndex = 0;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: Colors.black,
              insetPadding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.of(context).size.height * 0.78,
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: photosFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CircularProgressIndicator(
                          color: PosColors.accent,
                        ),
                      );
                    }

                    if (snapshot.hasError) {
                      return _galleryScaffold(
                        context: context,
                        child: Center(
                          child: Text(
                            'Failed to load photos.',
                            style: GoogleFonts.notoSansKr(color: Colors.white),
                          ),
                        ),
                      );
                    }

                    final photos = snapshot.data ?? const [];
                    if (photos.isEmpty) {
                      return _galleryScaffold(
                        context: context,
                        child: Center(
                          child: Text(
                            'No photos available.',
                            style: GoogleFonts.notoSansKr(color: Colors.white),
                          ),
                        ),
                      );
                    }

                    final activePhoto = photos[currentIndex];

                    return _galleryScaffold(
                      context: context,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Photo ${currentIndex + 1} / ${photos.length}',
                                    style: GoogleFonts.notoSansKr(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if ((activePhoto['photo_role']?.toString() ??
                                        '')
                                    .isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.14,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      activePhoto['photo_role']
                                          .toString()
                                          .toUpperCase(),
                                      style: GoogleFonts.notoSansKr(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: PageView.builder(
                              controller: pageController,
                              itemCount: photos.length,
                              onPageChanged: (index) {
                                setDialogState(() => currentIndex = index);
                              },
                              itemBuilder: (context, index) {
                                final url =
                                    photos[index]['photo_url']?.toString() ??
                                    '';
                                return InteractiveViewer(
                                  minScale: 0.8,
                                  maxScale: 4,
                                  child: Image.network(
                                    url,
                                    fit: BoxFit.contain,
                                  ),
                                );
                              },
                            ),
                          ),
                          if ((activePhoto['caption']?.toString() ?? '')
                              .isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: Text(
                                activePhoto['caption'].toString(),
                                style: GoogleFonts.notoSansKr(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (photos.length > 1)
                            SizedBox(
                              height: 88,
                              child: ListView.separated(
                                padding: const EdgeInsets.all(12),
                                scrollDirection: Axis.horizontal,
                                itemCount: photos.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final url =
                                      photos[index]['photo_url']?.toString() ??
                                      '';
                                  final selected = index == currentIndex;
                                  return GestureDetector(
                                    onTap: () {
                                      pageController.jumpToPage(index);
                                      setDialogState(
                                        () => currentIndex = index,
                                      );
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: selected
                                              ? PosColors.accent
                                              : Colors.white24,
                                          width: selected ? 2 : 1,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(7),
                                        child: Image.network(
                                          url,
                                          width: 64,
                                          height: 64,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _galleryScaffold({
    required BuildContext context,
    required Widget child,
  }) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ),
      ],
    );
  }
}
