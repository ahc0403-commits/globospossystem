import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/live_sync_scope.dart';
import 'network_capability_service.dart';
import 'printer_service.dart';
import 'printer_diagnostics.dart';
import 'receipt_builder.dart';
import 'wifi_printer_service.dart';

abstract class PrintAgentDriver {
  bool get isSupported;
  Future<void> startPollingSafely(String storeId, {bool receiptOnly = false});
  Future<void> stopSafely();
  Future<List<PrintJobAgentResult>> processOnce(String storeId, {int limit});
  Future<PrintResult> testPrintDestination(String destinationId);
}

class PrintJobAgentService implements PrintAgentDriver, DiagnosticPrintAgent {
  PrintJobAgentService({
    PrintJobBackend? backend,
    PrinterService? printerService,
    NetworkCapabilityService? networkCapabilityService,
  }) : _backend = backend ?? SupabasePrintJobBackend(Supabase.instance.client),
       _printerService = printerService ?? createPrinterService(),
       _networkCapabilityService =
           networkCapabilityService ?? const NativeNetworkCapabilityService();

  final PrintJobBackend _backend;
  final PrinterService _printerService;
  final NetworkCapabilityService _networkCapabilityService;
  Timer? _pollTimer;
  bool _isProcessing = false;
  bool _receiptOnly = false;
  Future<void>? _processingDone;
  int _lifecycleGeneration = 0;
  String? _activeStoreId;

  @override
  bool get isSupported => !kIsWeb && _printerService.isSupported;

  void startPolling(
    String storeId, {
    bool receiptOnly = false,
    Duration interval = const Duration(seconds: 15),
    int limit = 10,
  }) {
    unawaited(
      startPollingSafely(
        storeId,
        receiptOnly: receiptOnly,
        interval: interval,
        limit: limit,
      ),
    );
  }

  void stop() {
    unawaited(stopSafely());
  }

  @override
  Future<void> startPollingSafely(
    String storeId, {
    bool receiptOnly = false,
    Duration interval = const Duration(seconds: 15),
    int limit = 10,
  }) async {
    final generation = ++_lifecycleGeneration;
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeStoreId = null;
    await _backend.unsubscribeFromJobs();
    if (generation != _lifecycleGeneration || !isSupported) return;

    // Ensure an old batch cannot observe a new policy midway through printing.
    await _processingDone;
    if (generation != _lifecycleGeneration) return;
    _receiptOnly = receiptOnly;
    if (receiptOnly) {
      // Validate the receipt-only RPC before starting; zero never claims jobs.
      await _backend.claimJobs(storeId, limit: 0, receiptOnly: true);
    }
    if (generation != _lifecycleGeneration) return;
    _activeStoreId = storeId;
    await _backend.subscribeToJobs(storeId, () {
      if (generation == _lifecycleGeneration && _activeStoreId == storeId) {
        unawaited(processOnce(storeId, limit: limit));
      }
    });
    if (generation != _lifecycleGeneration || _activeStoreId != storeId) {
      return;
    }
    unawaited(processOnce(storeId, limit: limit));
    _pollTimer = Timer.periodic(interval, (_) {
      if (generation == _lifecycleGeneration && _activeStoreId == storeId) {
        unawaited(processOnce(storeId, limit: limit));
      }
    });
  }

  @override
  Future<void> stopSafely() async {
    _lifecycleGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeStoreId = null;
    await _backend.unsubscribeFromJobs();
    await _processingDone;
  }

  @override
  Future<List<PrintJobAgentResult>> processOnce(
    String storeId, {
    int limit = 10,
  }) async {
    if (!isSupported || _isProcessing) {
      return const [];
    }

    _isProcessing = true;
    final done = Completer<void>();
    _processingDone = done.future;
    try {
      final jobs = await _backend.claimJobs(
        storeId,
        limit: limit,
        receiptOnly: _receiptOnly,
      );
      final destinations = await _backend.loadDestinations(
        jobs
            .map((job) => job.destinationId)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList(),
      );
      final results = <PrintJobAgentResult>[];
      for (final job in jobs) {
        results.add(await _processJob(job, destinations[job.destinationId]));
      }
      return results;
    } finally {
      _isProcessing = false;
      done.complete();
      _processingDone = null;
    }
  }

  Future<PrintJobAgentResult> _processJob(
    PrintAgentJob job,
    PrintDestination? destination,
  ) async {
    final destinationId = job.destinationId;
    if (destinationId == null || destinationId.isEmpty) {
      await _backend.completeJob(job.id, ok: false, error: 'NO_DESTINATION');
      return PrintJobAgentResult(
        jobId: job.id,
        result: PrintResult.connectionFailed,
        error: 'NO_DESTINATION',
      );
    }

    if (destination == null) {
      await _backend.completeJob(
        job.id,
        ok: false,
        error: 'DESTINATION_NOT_FOUND',
      );
      return PrintJobAgentResult(
        jobId: job.id,
        result: PrintResult.connectionFailed,
        error: 'DESTINATION_NOT_FOUND',
      );
    }

    if (_receiptOnly && destination.purpose != 'receipt') {
      throw StateError('PRINT_STATION_RECEIPT_ROUTING_VIOLATION');
    }

    final ticketBytes = await _buildBytes(job);
    final bytes = <int>[
      if (destination.usesOperationalAlert)
        ...ReceiptBuilder.internalBuzzerAlertBytes,
      ...ticketBytes,
    ];
    final copyCount = _copyCountForTicket(job.ticket.ticket);
    final outcome = await _printToDestination(
      destination,
      bytes,
      copyCount: copyCount,
    );
    final ok = outcome.result == PrintResult.success;
    await _backend.completeJob(
      job.id,
      ok: ok,
      error: ok ? null : outcome.error,
    );
    return PrintJobAgentResult(
      jobId: job.id,
      result: outcome.result,
      error: ok ? null : outcome.error,
    );
  }

  @override
  Future<PrintResult> testPrintDestination(String destinationId) async =>
      (await diagnoseDestination(destinationId, printTicket: true)).result;

  @override
  Future<PrinterTestReport> diagnoseDestination(
    String destinationId, {
    required bool printTicket,
  }) async {
    if (!isSupported) {
      return const PrinterTestReport(result: PrintResult.notSupported);
    }
    try {
      final destination = await _backend.loadDestination(destinationId);
      if (destination == null) {
        return const PrinterTestReport(
          result: PrintResult.connectionFailed,
          errorCode: 'DESTINATION_NOT_FOUND',
        );
      }
      if (_receiptOnly && destination.purpose != 'receipt') {
        return const PrinterTestReport(
          result: PrintResult.noAllowedEndpoint,
          errorCode: 'PAPERLESS_CASHIER_ONLY',
        );
      }
      List<int>? bytes;
      if (printTicket) {
        final ticketBytes = await ReceiptBuilder.buildKitchenTicket(
          PrintTicket(
            ticket: 'kitchen',
            floorLabel: 'THU',
            tableNumber: 'MAY IN',
            ticketCode: 'TEST',
            batchNo: 1,
            printedReason: 'initial',
            printedAt: DateTime.now().toIso8601String(),
            items: const [PrintTicketItem(label: 'Thu duong in', quantity: 1)],
            orderNotes: 'Thu tram in',
          ),
        );
        bytes = <int>[
          if (destination.usesOperationalAlert)
            ...ReceiptBuilder.internalBuzzerAlertBytes,
          ...ticketBytes,
        ];
      }
      final outcome = await _printToDestination(
        destination,
        bytes,
        copyCount: printTicket && destination.purpose == 'floor' ? 2 : 1,
      );
      return PrinterTestReport(
        result: outcome.result,
        attempts: outcome.attempts,
        errorCode: outcome.error,
      );
    } catch (_) {
      return const PrinterTestReport(
        result: PrintResult.connectionFailed,
        errorCode: 'PRINTER_TEST_SETUP_FAILED',
      );
    }
  }

  int _copyCountForTicket(String ticketType) {
    return ticketType == 'floor' || ticketType == 'confirmation' ? 2 : 1;
  }

  Future<_EndpointPrintOutcome> _printToDestination(
    PrintDestination destination,
    List<int>? bytes, {
    int copyCount = 1,
  }) async {
    final configuredEndpoints = destination.endpoints.isEmpty
        ? <PrinterEndpoint>[
            PrinterEndpoint(
              id: 'legacy-${destination.id}',
              type: PrinterEndpointType.wireless,
              ip: destination.ip,
              port: destination.port,
              priority: 100,
              isActive: true,
            ),
          ]
        : destination.endpoints;
    final candidates =
        configuredEndpoints.where((endpoint) => endpoint.isActive).toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
    if (candidates.isEmpty) {
      return const _EndpointPrintOutcome(
        result: PrintResult.noAllowedEndpoint,
        error: 'NO_ALLOWED_PRINTER_ENDPOINT',
      );
    }

    final hasUsbEndpoint = candidates.any(
      (endpoint) => endpoint.type == PrinterEndpointType.usb,
    );
    if (!hasUsbEndpoint) {
      NetworkCapabilities capabilities;
      try {
        capabilities = await _networkCapabilityService.loadCapabilities();
      } catch (_) {
        return const _EndpointPrintOutcome(
          result: PrintResult.networkUnavailable,
          error: 'NETWORK_CAPABILITIES_UNAVAILABLE',
        );
      }
      if (!capabilities.hasNetwork) {
        return const _EndpointPrintOutcome(
          result: PrintResult.networkUnavailable,
          error: 'NETWORK_UNAVAILABLE',
        );
      }
    }

    final failures = <String>[];
    final attempts = <PrinterEndpointAttempt>[];
    var lastResult = PrintResult.connectionFailed;
    for (final endpoint in candidates) {
      var printedCopies = 0;
      var status = const PrinterOperationStatus(PrintResult.success);
      while (printedCopies < copyCount) {
        status = await _operateEndpoint(endpoint, bytes);
        attempts.add(
          PrinterEndpointAttempt(
            type: endpoint.type.name,
            address: endpoint.displayAddress,
            status: status,
          ),
        );
        if (status.result != PrintResult.success) break;
        printedCopies++;
      }
      if (printedCopies == copyCount) {
        return _EndpointPrintOutcome(
          result: PrintResult.success,
          endpoint: endpoint,
          attempts: attempts,
        );
      }
      lastResult = status.result;
      failures.add(
        '${endpoint.type.name}@${endpoint.displayAddress}=${status.result.name}',
      );
      // Never resend a possibly printed ticket through another endpoint.
      if (printedCopies > 0 || status.mayHavePrinted) {
        return _EndpointPrintOutcome(
          result: status.result,
          endpoint: endpoint,
          attempts: attempts,
          error: 'PARTIAL_PRINT:${failures.join(',')}',
        );
      }
    }
    return _EndpointPrintOutcome(
      result: lastResult,
      attempts: attempts,
      error: 'ALL_ENDPOINTS_FAILED:${failures.join(',')}',
    );
  }

  Future<PrinterOperationStatus> _operateEndpoint(
    PrinterEndpoint endpoint,
    List<int>? bytes,
  ) async {
    if (_printerService is DiagnosticPrinterService) {
      final service = _printerService as DiagnosticPrinterService;
      if (endpoint.type == PrinterEndpointType.usb) {
        return bytes == null
            ? service.checkUsbPrinter(endpoint.deviceName)
            : service.printWindowsPrinter(endpoint.deviceName, bytes);
      }
      return bytes == null
          ? service.checkNetworkPrinter(endpoint.ip, port: endpoint.port)
          : service.printNetworkPrinter(
              endpoint.ip,
              bytes,
              port: endpoint.port,
            );
    }
    if (bytes == null) {
      return PrinterOperationStatus(
        endpoint.type != PrinterEndpointType.usb &&
                await _printerService.testConnection(
                  endpoint.ip,
                  port: endpoint.port,
                )
            ? PrintResult.success
            : PrintResult.connectionFailed,
      );
    }
    final result = endpoint.type == PrinterEndpointType.usb
        ? _printerService is UsbPrinterService
              ? await (_printerService as UsbPrinterService).printUsbReceipt(
                  endpoint.deviceName,
                  bytes,
                )
              : PrintResult.notSupported
        : await _printerService.printReceipt(
            endpoint.ip,
            bytes,
            port: endpoint.port,
          );
    return PrinterOperationStatus(result);
  }

  Future<List<int>> _buildBytes(PrintAgentJob job) {
    return switch (job.ticket.ticket) {
      'request_update' => ReceiptBuilder.buildRequestUpdate(job.ticket),
      'receipt' => _buildPaymentReceipt(job.payload),
      'floor' => ReceiptBuilder.buildFloorTicket(job.ticket),
      'tray' => ReceiptBuilder.buildTrayLabel(job.ticket),
      'confirmation' => ReceiptBuilder.buildConfirmationSlip(job.ticket),
      _ => ReceiptBuilder.buildKitchenTicket(job.ticket),
    };
  }

  Future<List<int>> _buildPaymentReceipt(Map<String, dynamic> payload) {
    final receipt = QueuedPaymentReceipt.fromPayload(payload);
    return ReceiptBuilder.buildPaymentReceipt(
      restaurantName: receipt.restaurantName,
      tableNumber: receipt.tableNumber,
      items: receipt.items,
      totalAmount: receipt.totalAmount,
      paymentMethod: receipt.paymentMethod,
      paidAt: receipt.paidAt,
      bank: receipt.bank,
      isService: receipt.isService,
      legalName: receipt.legalName,
      taxCode: receipt.taxCode,
      addressLines: receipt.addressLines,
      receiptNumber: receipt.receiptNumber,
      cashierCode: receipt.cashierCode,
      subtotalAmount: receipt.subtotalAmount,
      discountAmount: receipt.discountAmount,
      vatAmount: receipt.vatAmount,
      receivedAmount: receipt.receivedAmount,
      changeAmount: receipt.changeAmount,
      directFulfillmentType: receipt.directFulfillmentType,
      directDeliveryPaymentMode: receipt.directDeliveryPaymentMode,
      directReferenceCode: receipt.directReferenceCode,
      dinerCount: receipt.dinerCount,
      utensilsRequested: receipt.utensilsRequested,
      fulfillmentMethod: receipt.fulfillmentMethod,
      deliveryPaymentMode: receipt.deliveryPaymentMode,
      directOrderReference: receipt.directOrderReference,
      orderNotes: receipt.orderNotes,
      refundedTotal: receipt.refundedTotal,
    );
  }
}

abstract class PrintJobBackend {
  Future<List<PrintAgentJob>> claimJobs(
    String storeId, {
    int limit = 10,
    bool receiptOnly = false,
  });
  Future<PrintDestination?> loadDestination(String destinationId);
  Future<Map<String, PrintDestination>> loadDestinations(
    List<String> destinationIds,
  );
  Future<void> completeJob(String jobId, {required bool ok, String? error});

  Future<void> subscribeToJobs(
    String storeId,
    void Function() onChanged,
  ) async {}

  Future<void> unsubscribeFromJobs() async {}
}

class SupabasePrintJobBackend implements PrintJobBackend {
  SupabasePrintJobBackend(this._client);

  final SupabaseClient _client;
  RealtimeChannel? _printJobsChannel;
  String? _subscribedStoreId;

  @override
  Future<List<PrintAgentJob>> claimJobs(
    String storeId, {
    int limit = 10,
    bool receiptOnly = false,
  }) async {
    final params = {'p_store_id': storeId, 'p_limit': limit};
    dynamic response;
    if (receiptOnly) {
      // Never fall back to a claim that could consume operational printer jobs.
      response = await _client.rpc(
        'claim_print_station_receipt_jobs',
        params: params,
      );
    } else {
      try {
        response = await _client.rpc('claim_print_jobs_v3', params: params);
      } on PostgrestException catch (error) {
        // Install upgraded stations before the DB rollout. Only an absent RPC
        // permits the predecessor claim; auth, routing and network errors stop.
        if (error.code != 'PGRST202') rethrow;
        response = await _client.rpc('claim_print_jobs_v2', params: params);
      }
    }
    final rows = response is List ? response : const <Object?>[];
    return rows
        .whereType<Map>()
        .map((row) => PrintAgentJob.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<PrintDestination?> loadDestination(String destinationId) async {
    return (await loadDestinations([destinationId]))[destinationId];
  }

  @override
  Future<Map<String, PrintDestination>> loadDestinations(
    List<String> destinationIds,
  ) async {
    if (destinationIds.isEmpty) return const {};
    final rows = await _client
        .from('printer_destinations')
        .select('id, name, ip, port, purpose, physical_printer_id')
        .inFilter('id', destinationIds);
    final physicalIds = rows
        .map((row) => row['physical_printer_id'])
        .whereType<String>()
        .toSet()
        .toList();
    final endpoints = <String, List<Map<String, dynamic>>>{};
    if (physicalIds.isNotEmpty) {
      final endpointRows = await _client
          .from('printer_endpoints')
          .select(
            'id, physical_printer_id, endpoint_type, ip, device_name, port, priority, is_active',
          )
          .inFilter('physical_printer_id', physicalIds)
          .eq('is_active', true)
          .order('priority');
      for (final row in endpointRows) {
        (endpoints[row['physical_printer_id']] ??= []).add(row);
      }
    }
    return {
      for (final row in rows)
        row['id'] as String: PrintDestination.fromJson({
          ...row,
          'endpoints':
              endpoints[row['physical_printer_id']] ??
              const <Map<String, dynamic>>[],
        }),
    };
  }

  @override
  Future<void> completeJob(
    String jobId, {
    required bool ok,
    String? error,
  }) async {
    await _client.rpc(
      'complete_print_job',
      params: {'p_job_id': jobId, 'p_ok': ok, 'p_error': error},
    );
  }

  @override
  Future<void> subscribeToJobs(
    String storeId,
    void Function() onChanged,
  ) async {
    if (_printJobsChannel != null && _subscribedStoreId == storeId) {
      return;
    }

    await unsubscribeFromJobs();
    _subscribedStoreId = storeId;
    _printJobsChannel = _client
        .channel(LiveSyncScope.storeChannel('print_jobs', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'print_jobs',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => onChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'print_jobs',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => onChanged(),
        )
        .subscribe();
  }

  @override
  Future<void> unsubscribeFromJobs() async {
    final channel = _printJobsChannel;
    _printJobsChannel = null;
    _subscribedStoreId = null;
    await channel?.unsubscribe();
  }
}

class PrintAgentJob {
  const PrintAgentJob({
    required this.id,
    required this.destinationId,
    required this.ticket,
    this.payload = const <String, dynamic>{},
  });

  final String id;
  final String? destinationId;
  final PrintTicket ticket;
  final Map<String, dynamic> payload;

  factory PrintAgentJob.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    final payloadMap = payload is Map<String, dynamic>
        ? payload
        : Map<String, dynamic>.from(payload as Map);
    return PrintAgentJob(
      id: json['id'].toString(),
      destinationId: json['destination_id']?.toString(),
      ticket: PrintTicket.fromPayload(payloadMap),
      payload: payloadMap,
    );
  }
}

class PrintDestination {
  const PrintDestination({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.purpose = 'kitchen',
    this.endpoints = const <PrinterEndpoint>[],
  });

  final String id;
  final String name;
  final String ip;
  final int port;
  final String purpose;
  final List<PrinterEndpoint> endpoints;

  bool get usesOperationalAlert => purpose == 'kitchen' || purpose == 'floor';

  factory PrintDestination.fromJson(Map<String, dynamic> json) {
    final parsedEndpoints = (json['endpoints'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map(
          (endpoint) =>
              PrinterEndpoint.fromJson(Map<String, dynamic>.from(endpoint)),
        )
        .toList();
    return PrintDestination(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? '',
      ip: json['ip']?.toString() ?? '',
      port: switch (json['port']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 9100,
        _ => 9100,
      },
      purpose: json['purpose']?.toString() ?? 'kitchen',
      endpoints: parsedEndpoints.isEmpty
          ? [
              PrinterEndpoint(
                id: 'legacy-${json['id']}',
                type: PrinterEndpointType.wireless,
                ip: json['ip']?.toString() ?? '',
                port: switch (json['port']) {
                  int value => value,
                  num value => value.toInt(),
                  String value => int.tryParse(value) ?? 9100,
                  _ => 9100,
                },
                priority: 100,
                isActive: true,
              ),
            ]
          : parsedEndpoints,
    );
  }
}

enum PrinterEndpointType { usb, wired, wireless }

class PrinterEndpoint {
  const PrinterEndpoint({
    required this.id,
    required this.type,
    required this.ip,
    this.deviceName = '',
    required this.port,
    required this.priority,
    required this.isActive,
  });

  final String id;
  final PrinterEndpointType type;
  final String ip;
  final String deviceName;
  final int port;
  final int priority;
  final bool isActive;

  String get displayAddress =>
      type == PrinterEndpointType.usb ? deviceName : '$ip:$port';

  factory PrinterEndpoint.fromJson(Map<String, dynamic> json) {
    return PrinterEndpoint(
      id: json['id']?.toString() ?? '',
      type: switch (json['endpoint_type']?.toString()) {
        'usb' => PrinterEndpointType.usb,
        'wired' => PrinterEndpointType.wired,
        _ => PrinterEndpointType.wireless,
      },
      ip: json['ip']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      port: switch (json['port']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 9100,
        _ => 9100,
      },
      priority: switch (json['priority']) {
        int value => value,
        num value => value.toInt(),
        _ => 100,
      },
      isActive: json['is_active'] != false,
    );
  }
}

class _EndpointPrintOutcome {
  const _EndpointPrintOutcome({
    required this.result,
    this.endpoint,
    this.error,
    this.attempts = const [],
  });

  final PrintResult result;
  final PrinterEndpoint? endpoint;
  final String? error;
  final List<PrinterEndpointAttempt> attempts;
}

class PrintJobAgentResult {
  const PrintJobAgentResult({
    required this.jobId,
    required this.result,
    this.error,
  });

  final String jobId;
  final PrintResult result;
  final String? error;
}
