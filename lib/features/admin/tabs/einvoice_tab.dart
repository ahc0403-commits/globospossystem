import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';

class _EinvoiceOpsFlags {
  const _EinvoiceOpsFlags({required this.dispatchEnabled});

  final bool dispatchEnabled;
}

class _MeInvoiceReadiness {
  const _MeInvoiceReadiness({
    required this.taxEntityId,
    required this.taxCode,
    required this.sellerName,
    required this.integrationStatus,
    required this.pendingManualConfigCount,
    required this.dispatchPausedCount,
    required this.readyToDispatch,
    required this.blockingReasons,
  });

  factory _MeInvoiceReadiness.fromJson(Map<String, dynamic> json) {
    final reasonsRaw = json['blocking_reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw.map((reason) => reason.toString()).toList()
        : const <String>[];

    return _MeInvoiceReadiness(
      taxEntityId: json['tax_entity_id']?.toString() ?? '',
      taxCode: json['tax_code']?.toString() ?? '',
      sellerName: json['seller_name']?.toString() ?? '',
      integrationStatus:
          json['integration_status']?.toString() ?? 'needs_vendor_activation',
      pendingManualConfigCount: _toInt(json['pending_manual_config_count']),
      dispatchPausedCount: _toInt(json['dispatch_paused_count']),
      readyToDispatch: json['ready_to_dispatch'] == true,
      blockingReasons: reasons,
    );
  }

  final String taxEntityId;
  final String taxCode;
  final String sellerName;
  final String integrationStatus;
  final int pendingManualConfigCount;
  final int dispatchPausedCount;
  final bool readyToDispatch;
  final List<String> blockingReasons;

  bool get configReady =>
      !blockingReasons.contains('integration_not_active') &&
      !blockingReasons.contains('app_id_missing') &&
      !blockingReasons.contains('invoice_series_missing');

  bool get hasSetupBlockedJobs =>
      pendingManualConfigCount > 0 || dispatchPausedCount > 0;

  String optionLabel(BuildContext context) {
    final name = sellerName.isEmpty ? context.l10n.store : sellerName;
    if (taxCode.isEmpty) return name;
    return '$name · $taxCode';
  }
}

class _MeInvoiceSellerConfig {
  const _MeInvoiceSellerConfig({
    required this.taxEntityId,
    required this.taxCode,
    required this.sellerName,
    required this.authBaseUrl,
    required this.apiBaseUrl,
    required this.appId,
    required this.invoiceSeries,
    required this.paymentMethodCash,
    required this.paymentMethodCard,
    required this.paymentMethodPay,
    required this.paymentMethodMixed,
    required this.integrationStatus,
  });

  factory _MeInvoiceSellerConfig.fromReadiness(_MeInvoiceReadiness profile) {
    return _MeInvoiceSellerConfig(
      taxEntityId: profile.taxEntityId,
      taxCode: profile.taxCode,
      sellerName: profile.sellerName,
      authBaseUrl: 'https://api.meinvoice.vn/api/integration',
      apiBaseUrl: 'https://api.meinvoice.vn/api/integration/invoice',
      appId: '',
      invoiceSeries: '',
      paymentMethodCash: 'Tiền mặt',
      paymentMethodCard: 'Thẻ quốc tế',
      paymentMethodPay: 'Ví điện tử/QR',
      paymentMethodMixed: 'Tiền mặt/Thẻ/Ví điện tử',
      integrationStatus: profile.integrationStatus,
    );
  }

  factory _MeInvoiceSellerConfig.fromJson(Map<String, dynamic> json) {
    final taxEntityRaw = json['tax_entity'];
    final taxEntity = taxEntityRaw is Map<String, dynamic>
        ? taxEntityRaw
        : taxEntityRaw is Map
        ? Map<String, dynamic>.from(taxEntityRaw)
        : const <String, dynamic>{};

    return _MeInvoiceSellerConfig(
      taxEntityId: json['tax_entity_id']?.toString() ?? '',
      taxCode: taxEntity['tax_code']?.toString() ?? '',
      sellerName: taxEntity['name']?.toString() ?? '',
      authBaseUrl:
          json['auth_base_url']?.toString() ??
          'https://api.meinvoice.vn/api/integration',
      apiBaseUrl:
          json['api_base_url']?.toString() ??
          'https://api.meinvoice.vn/api/integration/invoice',
      appId: json['app_id']?.toString() ?? '',
      invoiceSeries: json['invoice_series']?.toString() ?? '',
      paymentMethodCash: json['payment_method_cash']?.toString() ?? 'Tiền mặt',
      paymentMethodCard:
          json['payment_method_card']?.toString() ?? 'Thẻ quốc tế',
      paymentMethodPay:
          json['payment_method_pay']?.toString() ?? 'Ví điện tử/QR',
      paymentMethodMixed:
          json['payment_method_mixed']?.toString() ?? 'Tiền mặt/Thẻ/Ví điện tử',
      integrationStatus:
          json['integration_status']?.toString() ?? 'needs_vendor_activation',
    );
  }

  final String taxEntityId;
  final String taxCode;
  final String sellerName;
  final String authBaseUrl;
  final String apiBaseUrl;
  final String appId;
  final String invoiceSeries;
  final String paymentMethodCash;
  final String paymentMethodCard;
  final String paymentMethodPay;
  final String paymentMethodMixed;
  final String integrationStatus;
}

class _MeInvoiceJobEvent {
  const _MeInvoiceJobEvent({
    required this.id,
    required this.eventType,
    required this.description,
    required this.retryCount,
    required this.createdAt,
  });

  factory _MeInvoiceJobEvent.fromJson(Map<String, dynamic> json) {
    return _MeInvoiceJobEvent(
      id: json['id']?.toString() ?? '',
      eventType: json['event_type']?.toString() ?? '',
      description: json['description']?.toString(),
      retryCount: _toInt(json['retry_count']),
      createdAt: _toDateTime(json['created_at']),
    );
  }

  final String id;
  final String eventType;
  final String? description;
  final int retryCount;
  final DateTime createdAt;

  String get title => eventType.isEmpty ? '-' : eventType.replaceAll('_', ' ');
}

class _EinvoiceQueueItem {
  const _EinvoiceQueueItem({
    required this.id,
    required this.refId,
    required this.status,
    required this.sid,
    required this.errorClassification,
    required this.errorMessage,
    required this.dispatchAttempts,
    required this.retryCount,
    required this.createdAt,
    required this.updatedAt,
    required this.dispatchedAt,
    required this.lookupUrl,
    required this.redinvoiceRequested,
    required this.orderId,
    required this.storeId,
    required this.tableNumber,
    required this.taxCode,
    required this.salesChannel,
    required this.issuanceStatus,
    required this.cqtReportStatus,
    required this.supplyAmount,
    required this.vatAmount,
    required this.totalAmount,
  });

  factory _EinvoiceQueueItem.fromJson(Map<String, dynamic> json) {
    final orderRaw = json['orders'];
    final order = orderRaw is Map<String, dynamic>
        ? orderRaw
        : orderRaw is Map
        ? Map<String, dynamic>.from(orderRaw)
        : null;
    final tableRaw = order?['tables'];
    final table = tableRaw is Map<String, dynamic>
        ? tableRaw
        : tableRaw is Map
        ? Map<String, dynamic>.from(tableRaw)
        : null;
    final snapshotRaw = json['line_items_snapshot'];
    final itemsRaw = snapshotRaw is List ? snapshotRaw : order?['order_items'];
    final items = itemsRaw is List
        ? itemsRaw
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : const <Map<String, dynamic>>[];
    final activeItems = items
        .where((item) => item['status']?.toString() != 'cancelled')
        .toList();

    double supplyAmount = 0;
    double vatAmount = 0;
    double totalAmount = 0;
    for (final item in activeItems) {
      final supply = _toDouble(item['total_amount_ex_tax']);
      final vat = _toDouble(item['vat_amount']);
      final total = _toDouble(item['paying_amount_inc_tax']);
      final snapshotSupply = _toDouble(item['AmountWithoutVAT']);
      final snapshotVat = _toDouble(item['VATAmount']);
      final snapshotTotal = _toDouble(item['AmountAfterTax']);
      final resolvedSupply = supply > 0 ? supply : snapshotSupply;
      final resolvedVat = vat > 0 ? vat : snapshotVat;
      final resolvedTotal = total > 0 ? total : snapshotTotal;
      supplyAmount += resolvedSupply;
      vatAmount += resolvedVat;
      totalAmount += resolvedTotal > 0
          ? resolvedTotal
          : (resolvedSupply + resolvedVat);
    }
    final buyerKind = json['buyer_kind']?.toString() ?? 'anonymous';
    final status = json['status']?.toString() ?? 'pending_manual_config';
    final refValue = json['misa_ref_id']?.toString();

    return _EinvoiceQueueItem(
      id: json['id']?.toString() ?? '',
      refId: refValue != null && refValue.isNotEmpty
          ? refValue
          : json['id']?.toString() ?? '',
      status: status,
      sid: json['transaction_id']?.toString(),
      errorClassification: json['manual_action_type']?.toString(),
      errorMessage: json['error_message']?.toString(),
      dispatchAttempts: _toInt(json['dispatch_attempts']),
      retryCount: _toInt(json['dispatch_attempts']),
      createdAt: _toDateTime(json['created_at']),
      updatedAt: _toDateTime(json['updated_at'] ?? json['created_at']),
      dispatchedAt: _toNullableDateTime(
        json['sent_at'] ?? json['last_dispatch_at'],
      ),
      lookupUrl: null,
      redinvoiceRequested: buyerKind != 'anonymous',
      orderId: order?['id']?.toString() ?? json['order_id']?.toString() ?? '',
      storeId:
          order?['restaurant_id']?.toString() ??
          json['store_id']?.toString() ??
          '',
      tableNumber: table?['table_number']?.toString(),
      taxCode: (json['tax_entity'] as Map?)?['tax_code']?.toString(),
      salesChannel: order?['sales_channel']?.toString() ?? 'dine_in',
      issuanceStatus: json['invoice_number']?.toString().isNotEmpty == true
          ? json['invoice_number'].toString()
          : status,
      cqtReportStatus: json['tax_authority_code']?.toString().isNotEmpty == true
          ? json['tax_authority_code'].toString()
          : status,
      supplyAmount: supplyAmount,
      vatAmount: vatAmount,
      totalAmount: totalAmount,
    );
  }

  final String id;
  final String refId;
  final String status;
  final String? sid;
  final String? errorClassification;
  final String? errorMessage;
  final int dispatchAttempts;
  final int retryCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? dispatchedAt;
  final String? lookupUrl;
  final bool redinvoiceRequested;
  final String orderId;
  final String storeId;
  final String? tableNumber;
  final String? taxCode;
  final String salesChannel;
  final String? issuanceStatus;
  final String? cqtReportStatus;
  final double supplyAmount;
  final double vatAmount;
  final double totalAmount;

  bool get isResolved => status == 'resolved';
  bool get isFailed => status == 'failed' || status == 'manual_action_required';
  bool get isPendingPolling =>
      status == 'dispatch_paused' || status == 'pending_manual_config';
  bool get isCompleted =>
      status == 'valid_invoice' ||
      status == 'sent_to_tax_authority' ||
      status == 'sent_to_misa';

  String get groupStatus {
    if (isResolved) return 'resolved';
    if (isFailed) return 'failed';
    if (isCompleted) return 'completed';
    return 'pending';
  }

  String statusLabel(BuildContext context) {
    final l10n = context.l10n;
    if (isResolved) return l10n.einvoiceProcessed;
    return switch (status) {
      'pending' => l10n.einvoicePendingIssue,
      'pending_manual_config' ||
      'dispatch_paused' => l10n.deliveryRetryRequired,
      'sent_to_misa' || 'sent_to_tax_authority' => l10n.einvoiceSentComplete,
      'valid_invoice' => l10n.einvoiceIssued,
      'failed' => l10n.einvoiceFailed,
      'manual_action_required' => l10n.einvoiceImmediateReview,
      _ => l10n.einvoicePendingIssue,
    };
  }

  Color get statusColor {
    if (isResolved) return PosColors.textSecondary;
    return switch (groupStatus) {
      'failed' => PosColors.danger,
      'completed' => PosColors.success,
      _ => isPendingPolling ? PosColors.warning : PosColors.accent,
    };
  }

  String tableLabel(BuildContext context) {
    if (tableNumber != null && tableNumber!.isNotEmpty) {
      return 'T$tableNumber';
    }
    return salesChannelLabel(context);
  }

  String salesChannelLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (salesChannel) {
      'delivery' => l10n.deliveryHeaderTitle,
      'takeaway' => l10n.takeout,
      _ => l10n.store,
    };
  }

  String issuanceLabel(BuildContext context) => _normalizeExternalStatus(
    context,
    issuanceStatus,
    fallback: statusLabel(context),
  );

  String cqtLabel(BuildContext context) => _normalizeExternalStatus(
    context,
    cqtReportStatus,
    fallback: isCompleted
        ? context.l10n.einvoiceTaxAuthoritySubmission
        : context.l10n.pending,
  );

  String typeLabel(BuildContext context) => redinvoiceRequested
      ? context.l10n.redInvoice
      : context.l10n.einvoiceNormalIssue;
  String get orderShortId => orderId.isEmpty
      ? '-'
      : '#${orderId.substring(0, orderId.length < 8 ? orderId.length : 8)}';
}

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

int _toInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

DateTime _toDateTime(Object? value) {
  final parsed = _toNullableDateTime(value);
  return parsed ?? DateTime.now();
}

DateTime? _toNullableDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

String _normalizeExternalStatus(
  BuildContext context,
  String? raw, {
  required String fallback,
}) {
  final l10n = context.l10n;
  final value = raw?.trim();
  if (value == null || value.isEmpty) return fallback;
  final normalized = value.toLowerCase();
  if (normalized.contains('report') || normalized.contains('success')) {
    return l10n.einvoiceSentComplete;
  }
  if (normalized.contains('issued')) {
    return l10n.einvoiceIssued;
  }
  if (normalized.contains('reject')) {
    return l10n.einvoiceRejected;
  }
  if (normalized.contains('fail') || normalized.contains('error')) {
    return l10n.einvoiceFailed;
  }
  if (normalized.contains('pending') ||
      normalized.contains('wait') ||
      normalized.contains('dispatch')) {
    return l10n.pending;
  }
  return value.replaceAll('_', ' ');
}

final _einvoiceJobsProvider =
    FutureProvider.autoDispose<List<_EinvoiceQueueItem>>((ref) async {
      final result = await supabase
          .from('meinvoice_jobs')
          .select('''
            id, status, buyer_kind, buyer_snapshot, payment_method_snapshot,
            line_items_snapshot, manual_action_type, manual_action_note,
            error_message, dispatch_attempts, last_dispatch_at, sent_at,
            created_at, updated_at, misa_ref_id, transaction_id,
            invoice_series, invoice_number, tax_authority_code, search_code,
            order_id, store_id, tax_entity_id,
            orders (
              id, restaurant_id, sales_channel, created_at,
              tables ( table_number )
            ),
            tax_entity ( tax_code )
          ''')
          .order('created_at', ascending: false)
          .limit(200);
      return (result as List)
          .map(
            (entry) =>
                _EinvoiceQueueItem.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList();
    });

final _einvoiceOpsFlagsProvider =
    FutureProvider.autoDispose<_EinvoiceOpsFlags?>((ref) async {
      try {
        final result = await supabase
            .from('system_config')
            .select('key, value')
            .inFilter('key', ['meinvoice_dispatch_enabled']);

        final rows = (result as List)
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
        final values = <String, String>{
          for (final row in rows)
            row['key'].toString(): row['value']?.toString() ?? '',
        };

        return _EinvoiceOpsFlags(
          dispatchEnabled: _parseFlag(values['meinvoice_dispatch_enabled']),
        );
      } catch (_) {
        return null;
      }
    });

final _meinvoiceReadinessProvider =
    FutureProvider.autoDispose<List<_MeInvoiceReadiness>>((ref) async {
      try {
        final result = await supabase.rpc('get_meinvoice_readiness');
        final rows = result is List ? result : const [];
        return rows
            .whereType<Map>()
            .map(
              (entry) => _MeInvoiceReadiness.fromJson(
                Map<String, dynamic>.from(entry),
              ),
            )
            .toList();
      } catch (_) {
        return const <_MeInvoiceReadiness>[];
      }
    });

final _meinvoiceSellerConfigsProvider =
    FutureProvider.autoDispose<Map<String, _MeInvoiceSellerConfig>>((
      ref,
    ) async {
      final result = await supabase.from('meinvoice_tax_entity_config').select(
        '''
            tax_entity_id, auth_base_url, api_base_url, app_id,
            invoice_series, payment_method_cash, payment_method_card,
            payment_method_pay, payment_method_mixed, integration_status,
            tax_entity ( tax_code, name )
          ''',
      );
      final configs = <String, _MeInvoiceSellerConfig>{};
      for (final row in result) {
        final config = _MeInvoiceSellerConfig.fromJson(
          Map<String, dynamic>.from(row),
        );
        if (config.taxEntityId.isNotEmpty) {
          configs[config.taxEntityId] = config;
        }
      }
      return configs;
    });

final _meinvoiceJobEventsProvider = FutureProvider.autoDispose
    .family<List<_MeInvoiceJobEvent>, String>((ref, jobId) async {
      if (jobId.isEmpty) return const <_MeInvoiceJobEvent>[];
      final result = await supabase
          .from('meinvoice_job_events')
          .select('id, event_type, description, retry_count, created_at')
          .eq('job_id', jobId)
          .order('created_at', ascending: false)
          .limit(8);
      return (result as List)
          .map(
            (entry) =>
                _MeInvoiceJobEvent.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList();
    });

bool _parseFlag(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized == 'true' || normalized == '1' || normalized == 'yes';
}

class EinvoiceTab extends ConsumerStatefulWidget {
  const EinvoiceTab({super.key});

  @override
  ConsumerState<EinvoiceTab> createState() => _EinvoiceTabState();
}

class _EinvoiceTabState extends ConsumerState<EinvoiceTab> {
  String _statusFilter = 'all';
  String _periodFilter = 'month';
  String? _selectedJobId;
  String? _retryingJobId;
  String? _resolvingJobId;
  bool _releasingReadyJobs = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(_einvoiceJobsProvider);
    final flags = ref.watch(_einvoiceOpsFlagsProvider).valueOrNull;
    final readiness =
        ref.watch(_meinvoiceReadinessProvider).valueOrNull ??
        const <_MeInvoiceReadiness>[];
    final allJobs = jobsAsync.valueOrNull ?? const <_EinvoiceQueueItem>[];
    final filteredJobs = _filteredJobs(allJobs);
    final selectedJob = _resolveSelectedJob(filteredJobs);

    final pendingCount = allJobs
        .where((job) => job.groupStatus == 'pending')
        .length;
    final completedCount = allJobs
        .where((job) => job.groupStatus == 'completed')
        .length;
    final failedCount = allJobs
        .where((job) => job.groupStatus == 'failed')
        .length;
    final monthTotal = allJobs
        .where(
          (job) =>
              job.createdAt.year == DateTime.now().year &&
              job.createdAt.month == DateTime.now().month,
        )
        .fold<double>(0, (sum, job) => sum + job.totalAmount);
    final header = _buildEinvoiceExceptionHeader(
      pendingCount: pendingCount,
      completedCount: completedCount,
      failedCount: failedCount,
      monthTotal: monthTotal,
    );
    final alertWidgets = <Widget>[
      if (flags != null) ..._buildOpsAlerts(flags, allJobs),
      ..._buildReadinessAlerts(readiness),
    ];
    final opsAlerts = alertWidgets.isEmpty
        ? const <Widget>[]
        : <Widget>[...alertWidgets, const SizedBox(height: 12)];
    final queueControls = _buildEinvoiceQueueControls(
      filteredCount: filteredJobs.length,
    );

    return Scaffold(
      key: const Key('einvoice_root'),
      backgroundColor: PosColors.canvas,
      body: LayoutBuilder(
        builder: (context, viewport) {
          if (viewport.maxWidth < 1120) {
            return ToastResponsiveScrollBody(
              maxWidth: 1480,
              padding: const EdgeInsets.all(16),
              children: [
                header,
                ...opsAlerts,
                const SizedBox(height: 12),
                queueControls,
                const SizedBox(height: 16),
                jobsAsync.when(
                  loading: () => SizedBox(
                    height: 320,
                    child: ToastOperationalLoadingState(
                      label: PosLoadingCopy.loadingEinvoiceJobs(context.l10n),
                    ),
                  ),
                  error: (error, _) => _buildErrorState(error),
                  data: (_) {
                    if (filteredJobs.isEmpty) {
                      return _buildEmptyState();
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildQueuePane(
                          jobs: filteredJobs,
                          selectedJob: selectedJob,
                          scrollable: false,
                        ),
                        const SizedBox(height: 16),
                        _buildDetailPane(selectedJob, scrollable: false),
                      ],
                    );
                  },
                ),
              ],
            );
          }

          return ToastResponsiveBody(
            maxWidth: 1480,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                ...opsAlerts,
                const SizedBox(height: 12),
                queueControls,
                const SizedBox(height: 16),
                Expanded(
                  child: jobsAsync.when(
                    loading: () => ToastOperationalLoadingState(
                      label: PosLoadingCopy.loadingEinvoiceJobs(context.l10n),
                    ),
                    error: (error, _) => _buildErrorState(error),
                    data: (_) {
                      if (filteredJobs.isEmpty) {
                        return _buildEmptyState();
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 520,
                            child: _buildQueuePane(
                              jobs: filteredJobs,
                              selectedJob: selectedJob,
                              scrollable: true,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildDetailPane(
                              selectedJob,
                              scrollable: true,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEinvoiceExceptionHeader({
    required int pendingCount,
    required int completedCount,
    required int failedCount,
    required double monthTotal,
  }) {
    final l10n = context.l10n;
    final needsReview = failedCount > 0;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: PosColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.eInvoice,
                      style: Theme.of(
                        context,
                      ).textTheme.headlineLarge?.copyWith(letterSpacing: 0),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.einvoiceScreenSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: needsReview
                    ? l10n.deliveryRetryRequired
                    : l10n.staffOperationalHealthy,
                color: needsReview ? PosColors.warning : PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.einvoicePendingIssue,
                value: '$pendingCount',
                tone: pendingCount > 0
                    ? PosColors.accent
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: l10n.einvoiceFailureRejected,
                value: '$failedCount',
                tone: needsReview ? PosColors.danger : PosColors.success,
              ),
              ToastMetric(
                label: l10n.einvoiceIssued,
                value: '$completedCount',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: l10n.einvoiceMonthlyTotal,
                value: _fmtVnd(monthTotal),
                tone: PosColors.info,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ToastStatusBadge(
                label: needsReview
                    ? l10n.einvoiceImmediateReview
                    : l10n.einvoiceNoOpenItems,
                color: needsReview ? PosColors.danger : PosColors.success,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  needsReview
                      ? l10n.einvoiceCheckFailureReasonFirst
                      : l10n.einvoiceAwaitingTaxCheck,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEinvoiceQueueControls({required int filteredCount}) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      backgroundColor: PosColors.surface,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _toolbarChip(
            label: l10n.today,
            selected: _periodFilter == 'today',
            onTap: () => setState(() => _periodFilter = 'today'),
          ),
          _toolbarChip(
            label: l10n.last7Days,
            selected: _periodFilter == 'week',
            onTap: () => setState(() => _periodFilter = 'week'),
          ),
          _toolbarChip(
            label: l10n.thisMonth,
            selected: _periodFilter == 'month',
            onTap: () => setState(() => _periodFilter = 'month'),
          ),
          _toolbarChip(
            label: l10n.allStatuses,
            selected: _statusFilter == 'all',
            onTap: () => setState(() => _statusFilter = 'all'),
          ),
          _toolbarChip(
            label: l10n.einvoicePendingIssue,
            selected: _statusFilter == 'pending',
            onTap: () => setState(() => _statusFilter = 'pending'),
          ),
          _toolbarChip(
            label: l10n.einvoiceSentComplete,
            selected: _statusFilter == 'completed',
            onTap: () => setState(() => _statusFilter = 'completed'),
          ),
          _toolbarChip(
            label: l10n.einvoiceFailed,
            selected: _statusFilter == 'failed',
            onTap: () => setState(() => _statusFilter = 'failed'),
          ),
          _toolbarChip(
            label: l10n.einvoiceProcessed,
            selected: _statusFilter == 'resolved',
            onTap: () => setState(() => _statusFilter = 'resolved'),
          ),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.einvoiceSearchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          PosSecondaryButton(
            label: l10n.reportsDownload,
            icon: Icons.download_outlined,
            onPressed: filteredCount == 0
                ? null
                : () => _showDownloadHint(filteredCount),
          ),
          PosSecondaryButton(
            label: l10n.einvoiceMeInvoiceSettings,
            icon: Icons.tune_outlined,
            onPressed: _openMeInvoiceConfigDialog,
          ),
          PosSecondaryButton(
            label: l10n.einvoiceMeInvoiceReleaseReadyJobs,
            icon: Icons.playlist_add_check_outlined,
            onPressed: _releasingReadyJobs ? null : _releaseReadyMeInvoiceJobs,
          ),
        ],
      ),
    );
  }

  List<_EinvoiceQueueItem> _filteredJobs(List<_EinvoiceQueueItem> jobs) {
    final now = DateTime.now();
    return jobs.where((job) {
      if (_statusFilter != 'all' && job.groupStatus != _statusFilter) {
        return false;
      }

      final compareDate = job.updatedAt;
      final matchesPeriod = switch (_periodFilter) {
        'today' =>
          compareDate.year == now.year &&
              compareDate.month == now.month &&
              compareDate.day == now.day,
        'week' => compareDate.isAfter(now.subtract(const Duration(days: 7))),
        _ => compareDate.year == now.year && compareDate.month == now.month,
      };
      if (!matchesPeriod) return false;

      final query = _searchController.text.trim().toLowerCase();
      if (query.isEmpty) return true;

      return job.refId.toLowerCase().contains(query) ||
          job.orderId.toLowerCase().contains(query) ||
          (job.taxCode ?? '').toLowerCase().contains(query) ||
          (job.tableNumber ?? '').toLowerCase().contains(query);
    }).toList();
  }

  _EinvoiceQueueItem? _resolveSelectedJob(List<_EinvoiceQueueItem> jobs) {
    if (jobs.isEmpty) return null;
    if (_selectedJobId == null) return jobs.first;
    for (final job in jobs) {
      if (job.id == _selectedJobId) {
        return job;
      }
    }
    return jobs.first;
  }

  List<Widget> _buildOpsAlerts(
    _EinvoiceOpsFlags flags,
    List<_EinvoiceQueueItem> jobs,
  ) {
    final l10n = context.l10n;
    final alerts = <Widget>[];
    if (!flags.dispatchEnabled) {
      alerts.add(
        PosExceptionAlert(
          label: l10n.einvoiceDispatchPaused,
          detail: l10n.einvoiceDispatchPausedDetail,
          color: PosColors.danger,
          icon: Icons.pause_circle_outline_rounded,
        ),
      );
    }
    final pendingCount = jobs.where((job) => job.isPendingPolling).length;
    if (pendingCount > 0) {
      alerts.add(
        PosExceptionAlert(
          label: l10n.einvoiceDispatchPaused,
          detail: l10n.einvoiceDispatchPausedDetail,
          color: PosColors.warning,
          icon: Icons.settings_outlined,
        ),
      );
    }
    return alerts;
  }

  List<Widget> _buildReadinessAlerts(List<_MeInvoiceReadiness> profiles) {
    final blocked = profiles
        .where((profile) => !profile.readyToDispatch)
        .toList(growable: false);
    if (blocked.isEmpty) return const <Widget>[];

    final reasons =
        blocked.expand((profile) => profile.blockingReasons).toSet().toList()
          ..sort();
    final reasonSummary = reasons.isEmpty
        ? '-'
        : reasons.map(_readinessReasonLabel).join(', ');

    return [
      PosExceptionAlert(
        label: context.l10n.einvoiceMeInvoiceSetupRequired,
        detail: context.l10n.einvoiceMeInvoiceSetupRequiredDetail(
          blocked.length,
          reasonSummary,
        ),
        color: PosColors.warning,
        icon: Icons.fact_check_outlined,
      ),
    ];
  }

  String _readinessReasonLabel(String reason) {
    final l10n = context.l10n;
    return switch (reason) {
      'dispatch_disabled' => l10n.einvoiceMeInvoiceReasonDispatchDisabled,
      'integration_not_active' =>
        l10n.einvoiceMeInvoiceReasonIntegrationInactive,
      'app_id_missing' => l10n.einvoiceMeInvoiceReasonAppIdMissing,
      'invoice_series_missing' =>
        l10n.einvoiceMeInvoiceReasonInvoiceSeriesMissing,
      _ => reason.replaceAll('_', ' '),
    };
  }

  Widget _toolbarChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ToastFilterChip(label: label, selected: selected, onSelected: onTap);
  }

  Widget _buildQueuePane({
    required List<_EinvoiceQueueItem> jobs,
    required _EinvoiceQueueItem? selectedJob,
    required bool scrollable,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(12),
      child: ListView.separated(
        shrinkWrap: !scrollable,
        physics: scrollable ? null : const NeverScrollableScrollPhysics(),
        itemCount: jobs.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final job = jobs[index];
          final selected = selectedJob?.id == job.id;
          return InkWell(
            onTap: () => setState(() => _selectedJobId = job.id),
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: selected ? PosColors.accentMuted : PosColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? PosColors.accent : PosColors.border,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              job.redinvoiceRequested
                                  ? context.l10n.eInvoice
                                  : context.l10n.einvoiceSalesDispatchPending,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${job.tableLabel(context)} · ${job.orderShortId}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: PosColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      ToastStatusBadge(
                        label: job.statusLabel(context),
                        color: job.statusColor,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _metaPill(
                        Icons.business_outlined,
                        job.taxCode ?? context.l10n.einvoiceNoTaxCode,
                      ),
                      _metaPill(
                        Icons.receipt_long_outlined,
                        job.typeLabel(context),
                      ),
                      _metaPill(Icons.sync_alt_outlined, job.cqtLabel(context)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _queueStat(
                          label: context.l10n.einvoiceTotalAmount,
                          value: _fmtVnd(job.totalAmount),
                        ),
                      ),
                      Expanded(
                        child: _queueStat(
                          label: context.l10n.einvoiceIssueStatus,
                          value: job.issuanceLabel(context),
                        ),
                      ),
                    ],
                  ),
                  if ((job.errorClassification?.isNotEmpty ?? false) ||
                      (job.errorMessage?.isNotEmpty ?? false)) ...[
                    const SizedBox(height: 10),
                    Text(
                      job.errorClassification?.isNotEmpty == true
                          ? job.errorClassification!
                          : job.errorMessage!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: job.isFailed
                            ? PosColors.danger
                            : PosColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _queueStat({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: PosColors.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _buildDetailPane(_EinvoiceQueueItem? job, {required bool scrollable}) {
    if (job == null) {
      return _buildEmptyState(
        headline: context.l10n.einvoiceNoSelectionTitle,
        detail: context.l10n.einvoiceNoSelectionSubtitle,
      );
    }

    final isRetrying = _retryingJobId == job.id;
    final isResolving = _resolvingJobId == job.id;
    final eventsAsync = ref.watch(_meinvoiceJobEventsProvider(job.id));
    final detailContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.einvoiceSelectedIssue,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${job.tableLabel(context)} · ${job.orderShortId} · ${_formatDateTime(job.createdAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            ToastStatusBadge(
              label: job.statusLabel(context),
              color: job.statusColor,
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (job.isFailed || job.isPendingPolling)
          PosExceptionAlert(
            label: job.isPendingPolling
                ? context.l10n.einvoiceAwaitingTaxResponse
                : context.l10n.einvoiceCheckFailureReasonFirst,
            detail: job.errorMessage?.isNotEmpty == true
                ? job.errorMessage
                : job.errorClassification?.isNotEmpty == true
                ? job.errorClassification
                : context.l10n.einvoiceCheckDispatchAndTaxStatus,
            color: job.isFailed ? PosColors.danger : PosColors.warning,
            icon: job.isFailed
                ? Icons.priority_high_rounded
                : Icons.sync_problem_rounded,
          ),
        if (job.isFailed || job.isPendingPolling) const SizedBox(height: 14),
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: context.l10n.einvoiceTotalAmount,
              value: _fmtVnd(job.totalAmount),
              tone: PosColors.accent,
            ),
            ToastMetric(
              label: context.l10n.einvoiceVat,
              value: _fmtVnd(job.vatAmount),
            ),
            ToastMetric(
              label: context.l10n.einvoiceSupplyAmount,
              value: _fmtVnd(job.supplyAmount),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: isRetrying ? null : () => _runPrimaryAction(job),
          icon: isRetrying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.receipt_long_outlined),
          label: Text(context.l10n.einvoiceProcessIssue),
        ),
        if (job.isFailed && !job.isResolved) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: isResolving ? null : () => _markResolved(job),
            icon: isResolving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline, size: 16),
            label: Text(context.l10n.einvoiceProcessed),
          ),
        ],
        const SizedBox(height: 16),
        _EinvoiceJobSecondaryDetail(
          job: job,
          eventsAsync: eventsAsync,
          onOpenPortal: job.lookupUrl?.isNotEmpty == true
              ? () => launchUrl(Uri.parse(job.lookupUrl!))
              : null,
          onCopyRef: () => _copyRefId(job.refId),
        ),
      ],
    );

    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: scrollable
          ? SingleChildScrollView(child: detailContent)
          : detailContent,
    );
  }

  Widget _buildErrorState(Object error) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 28,
            color: PosColors.danger,
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.einvoiceLoadFailed,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '$error',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => ref.invalidate(_einvoiceJobsProvider),
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({String? headline, String? detail}) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: PosColors.panelMuted,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.receipt_long_outlined,
              color: PosColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            headline ?? context.l10n.einvoiceNoPendingItems,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            detail ?? context.l10n.einvoiceEmptySubtitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => ref.invalidate(_einvoiceJobsProvider),
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.refresh),
          ),
        ],
      ),
    );
  }

  Widget _metaPill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: PosColors.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Future<String> _requireStoreId(_EinvoiceQueueItem job) async {
    final auth = ref.read(authProvider);
    if (job.storeId.isEmpty) {
      throw Exception(context.l10n.einvoiceTargetStoreMissing);
    }
    if (auth.role != 'super_admin' && auth.storeId != job.storeId) {
      throw Exception(context.l10n.einvoiceSwitchStoreRequired);
    }
    return job.storeId;
  }

  Future<void> _runPrimaryAction(_EinvoiceQueueItem job) async {
    if (job.isFailed || job.isPendingPolling) {
      await _retryJob(job);
      return;
    }
    if (job.lookupUrl?.isNotEmpty == true) {
      await launchUrl(Uri.parse(job.lookupUrl!));
      return;
    }
    ref.invalidate(_einvoiceJobsProvider);
    if (!mounted) return;
    showSuccessToast(context, context.l10n.einvoiceQueueRefreshed);
  }

  Future<void> _retryJob(_EinvoiceQueueItem job) async {
    setState(() => _retryingJobId = job.id);
    try {
      final storeId = await _requireStoreId(job);
      await supabase.rpc(
        'admin_retry_meinvoice_job',
        params: {'p_job_id': job.id, 'p_store_id': storeId},
      );
      ref.invalidate(_einvoiceJobsProvider);
      ref.invalidate(_meinvoiceReadinessProvider);
      ref.invalidate(_meinvoiceJobEventsProvider(job.id));
      if (!mounted) return;
      showSuccessToast(context, context.l10n.einvoiceRetryRequested);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          context.l10n.einvoiceRetryFailedWithError('$error'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _retryingJobId = null);
      }
    }
  }

  Future<void> _markResolved(_EinvoiceQueueItem job) async {
    setState(() => _resolvingJobId = job.id);
    try {
      final storeId = await _requireStoreId(job);
      await supabase.rpc(
        'admin_mark_resolved_meinvoice_job',
        params: {'p_job_id': job.id, 'p_store_id': storeId},
      );
      ref.invalidate(_einvoiceJobsProvider);
      ref.invalidate(_meinvoiceReadinessProvider);
      ref.invalidate(_meinvoiceJobEventsProvider(job.id));
      if (!mounted) return;
      showSuccessToast(context, context.l10n.einvoiceExceptionResolved);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          context.l10n.einvoiceResolveFailedWithError('$error'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _resolvingJobId = null);
      }
    }
  }

  Future<void> _openMeInvoiceConfigDialog() async {
    final l10n = context.l10n;
    late final List<_MeInvoiceReadiness> profiles;
    late final Map<String, _MeInvoiceSellerConfig> configs;

    try {
      profiles = await ref.read(_meinvoiceReadinessProvider.future);
      configs = await ref.read(_meinvoiceSellerConfigsProvider.future);
    } catch (error) {
      if (!mounted) return;
      showErrorToast(
        context,
        l10n.einvoiceMeInvoiceConfigSaveFailedWithError('$error'),
      );
      return;
    }

    if (!mounted) return;
    if (profiles.isEmpty) {
      showErrorToast(context, l10n.einvoiceMeInvoiceNoSellerProfile);
      return;
    }

    final appIdController = TextEditingController();
    final invoiceSeriesController = TextEditingController();
    final authBaseUrlController = TextEditingController();
    final apiBaseUrlController = TextEditingController();
    final cashLabelController = TextEditingController();
    final cardLabelController = TextEditingController();
    final payLabelController = TextEditingController();
    final mixedLabelController = TextEditingController();

    var selectedProfile = profiles.firstWhere(
      (profile) => !profile.readyToDispatch,
      orElse: () => profiles.first,
    );
    var integrationStatus = selectedProfile.integrationStatus;
    var saving = false;

    void loadProfile(_MeInvoiceReadiness profile) {
      selectedProfile = profile;
      final config =
          configs[profile.taxEntityId] ??
          _MeInvoiceSellerConfig.fromReadiness(profile);
      appIdController.text = config.appId;
      invoiceSeriesController.text = config.invoiceSeries;
      authBaseUrlController.text = config.authBaseUrl;
      apiBaseUrlController.text = config.apiBaseUrl;
      cashLabelController.text = config.paymentMethodCash;
      cardLabelController.text = config.paymentMethodCard;
      payLabelController.text = config.paymentMethodPay;
      mixedLabelController.text = config.paymentMethodMixed;
      integrationStatus = config.integrationStatus;
    }

    loadProfile(selectedProfile);

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              Future<void> saveConfig() async {
                if (integrationStatus == 'active' &&
                    (appIdController.text.trim().isEmpty ||
                        invoiceSeriesController.text.trim().isEmpty)) {
                  showErrorToast(
                    dialogContext,
                    l10n.einvoiceMeInvoiceActiveRequiresConfig,
                  );
                  return;
                }

                setDialogState(() => saving = true);
                try {
                  await supabase.rpc(
                    'admin_upsert_meinvoice_tax_entity_config',
                    params: {
                      'p_tax_entity_id': selectedProfile.taxEntityId,
                      'p_app_id': appIdController.text.trim(),
                      'p_invoice_series': invoiceSeriesController.text.trim(),
                      'p_integration_status': integrationStatus,
                      'p_auth_base_url': authBaseUrlController.text.trim(),
                      'p_api_base_url': apiBaseUrlController.text.trim(),
                      'p_payment_method_cash': cashLabelController.text.trim(),
                      'p_payment_method_card': cardLabelController.text.trim(),
                      'p_payment_method_pay': payLabelController.text.trim(),
                      'p_payment_method_mixed': mixedLabelController.text
                          .trim(),
                    },
                  );
                  ref.invalidate(_meinvoiceSellerConfigsProvider);
                  ref.invalidate(_meinvoiceReadinessProvider);
                  ref.invalidate(_einvoiceJobsProvider);
                  if (!dialogContext.mounted) return;
                  Navigator.of(dialogContext).pop();
                  if (!mounted) return;
                  showSuccessToast(context, l10n.einvoiceMeInvoiceConfigSaved);
                } catch (error) {
                  if (dialogContext.mounted) {
                    showErrorToast(
                      dialogContext,
                      l10n.einvoiceMeInvoiceConfigSaveFailedWithError('$error'),
                    );
                  }
                } finally {
                  if (dialogContext.mounted) {
                    setDialogState(() => saving = false);
                  }
                }
              }

              return AlertDialog(
                title: Text(l10n.einvoiceMeInvoiceSettingsTitle),
                content: SizedBox(
                  width: 640,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<String>(
                          key: const Key('meinvoice_seller_profile_select'),
                          initialValue: selectedProfile.taxEntityId,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceSellerProfile,
                            border: const OutlineInputBorder(),
                          ),
                          items: profiles
                              .map(
                                (profile) => DropdownMenuItem(
                                  value: profile.taxEntityId,
                                  child: Text(
                                    profile.optionLabel(context),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: saving
                              ? null
                              : (taxEntityId) {
                                  final nextProfile = profiles.firstWhere(
                                    (profile) =>
                                        profile.taxEntityId == taxEntityId,
                                    orElse: () => selectedProfile,
                                  );
                                  setDialogState(() {
                                    loadProfile(nextProfile);
                                  });
                                },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'meinvoice_integration_status_${selectedProfile.taxEntityId}',
                          ),
                          initialValue: integrationStatus,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceIntegrationStatus,
                            border: const OutlineInputBorder(),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'needs_vendor_activation',
                              child: Text(
                                l10n.einvoiceMeInvoiceStatusNeedsActivation,
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'configured',
                              child: Text(
                                l10n.einvoiceMeInvoiceStatusConfigured,
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'active',
                              child: Text(l10n.einvoiceMeInvoiceStatusActive),
                            ),
                            DropdownMenuItem(
                              value: 'paused',
                              child: Text(l10n.einvoiceMeInvoiceStatusPaused),
                            ),
                          ],
                          onChanged: saving
                              ? null
                              : (value) => setDialogState(
                                  () => integrationStatus =
                                      value ?? integrationStatus,
                                ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_app_id_input'),
                          controller: appIdController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceAppId,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_invoice_series_input'),
                          controller: invoiceSeriesController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceInvoiceSeries,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_auth_base_url_input'),
                          controller: authBaseUrlController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceAuthBaseUrl,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_api_base_url_input'),
                          controller: apiBaseUrlController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceApiBaseUrl,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_cash_label_input'),
                          controller: cashLabelController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceCashLabel,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_card_label_input'),
                          controller: cardLabelController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceCardLabel,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_pay_label_input'),
                          controller: payLabelController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoicePayLabel,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('meinvoice_mixed_label_input'),
                          controller: mixedLabelController,
                          decoration: InputDecoration(
                            labelText: l10n.einvoiceMeInvoiceMixedLabel,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton.icon(
                    onPressed: saving ? null : saveConfig,
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(l10n.save),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      appIdController.dispose();
      invoiceSeriesController.dispose();
      authBaseUrlController.dispose();
      apiBaseUrlController.dispose();
      cashLabelController.dispose();
      cardLabelController.dispose();
      payLabelController.dispose();
      mixedLabelController.dispose();
    }
  }

  Future<void> _releaseReadyMeInvoiceJobs() async {
    setState(() => _releasingReadyJobs = true);
    try {
      final profiles = await ref.read(_meinvoiceReadinessProvider.future);
      final readyProfiles = profiles
          .where(
            (profile) => profile.configReady && profile.hasSetupBlockedJobs,
          )
          .toList(growable: false);

      if (readyProfiles.isEmpty) {
        if (!mounted) return;
        showErrorToast(context, context.l10n.einvoiceMeInvoiceNoReadyJobs);
        return;
      }

      var releasedCount = 0;
      for (final profile in readyProfiles) {
        final result = await supabase.rpc(
          'admin_release_meinvoice_ready_jobs',
          params: {'p_tax_entity_id': profile.taxEntityId, 'p_limit': 200},
        );
        if (result is Map) {
          releasedCount += _toInt(result['released_count']);
        }
      }

      ref.invalidate(_meinvoiceReadinessProvider);
      ref.invalidate(_einvoiceJobsProvider);
      if (!mounted) return;
      showSuccessToast(
        context,
        context.l10n.einvoiceMeInvoiceReleaseReadyJobsDone(releasedCount),
      );
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          context.l10n.einvoiceMeInvoiceReleaseReadyJobsFailedWithError(
            '$error',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _releasingReadyJobs = false);
      }
    }
  }

  void _showDownloadHint(int count) {
    showSuccessToast(context, context.l10n.einvoiceDownloadPrepared(count));
  }

  Future<void> _copyRefId(String refId) async {
    await Clipboard.setData(ClipboardData(text: refId));
    if (!mounted) return;
    showSuccessToast(context, context.l10n.einvoiceRefCopied);
  }

  String _fmtVnd(double amount) =>
      '${NumberFormat('#,###').format(amount.round())} ₫';

  String _formatDateTime(DateTime? value) {
    if (value == null) return '-';
    return DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
  }
}

class _EinvoiceJobSecondaryDetail extends StatelessWidget {
  const _EinvoiceJobSecondaryDetail({
    required this.job,
    required this.eventsAsync,
    required this.onCopyRef,
    this.onOpenPortal,
  });

  final _EinvoiceQueueItem job;
  final AsyncValue<List<_MeInvoiceJobEvent>> eventsAsync;
  final VoidCallback? onOpenPortal;
  final VoidCallback onCopyRef;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: ExpansionTile(
        key: const Key('einvoice_job_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: PosColors.textSecondary,
        collapsedIconColor: PosColors.textSecondary,
        title: Text(
          context.l10n.einvoiceCheckDispatchAndTaxStatus,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${context.l10n.einvoiceRefLabel} ${_shortRefId(job.refId)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
        children: [
          _detailRow(
            context,
            context.l10n.einvoiceTaxAuthoritySubmission,
            job.cqtLabel(context),
          ),
          _detailRow(
            context,
            context.l10n.einvoiceIssueStatus,
            job.issuanceLabel(context),
          ),
          _detailRow(
            context,
            context.l10n.einvoiceSupplierCode,
            job.taxCode ?? context.l10n.notRegistered,
          ),
          _detailRow(context, context.l10n.einvoiceRefLabel, job.refId),
          _detailRow(
            context,
            context.l10n.einvoiceDispatchedAt,
            _formatDateTime(job.dispatchedAt),
          ),
          _detailRow(
            context,
            context.l10n.einvoiceUpdatedAt,
            _formatDateTime(job.updatedAt),
          ),
          _detailRow(
            context,
            context.l10n.einvoiceRetryCount,
            context.l10n.einvoiceRetryCountValue(job.retryCount),
          ),
          const SizedBox(height: 4),
          _buildEventHistory(context),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onOpenPortal,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(context.l10n.einvoiceOpenTaxPortal),
              ),
              OutlinedButton.icon(
                onPressed: onCopyRef,
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: Text(context.l10n.einvoiceCopyRef),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 136,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventHistory(BuildContext context) {
    return Container(
      key: const Key('meinvoice_job_event_history'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.einvoiceEventHistory,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          eventsAsync.when(
            loading: () => Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  context.l10n.posLoadingSyncing,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
              ],
            ),
            error: (_, _) => Text(
              context.l10n.einvoiceEventHistoryLoadFailed,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.danger),
            ),
            data: (events) {
              if (events.isEmpty) {
                return Text(
                  context.l10n.einvoiceEventHistoryEmpty,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                );
              }
              return Column(
                children: [
                  for (final event in events)
                    _eventRow(context: context, event: event),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _eventRow({
    required BuildContext context,
    required _MeInvoiceJobEvent event,
  }) {
    final detail = event.description?.trim();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  event.title,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _formatDateTime(event.createdAt),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.einvoiceEventRetryCount(event.retryCount),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) return '-';
    return DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
  }

  String _shortRefId(String refId) {
    if (refId.length <= 18) return refId;
    return '${refId.substring(0, 8)}...${refId.substring(refId.length - 6)}';
  }
}
