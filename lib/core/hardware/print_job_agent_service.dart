import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/live_sync_scope.dart';
import 'network_capability_service.dart';
import 'printer_service.dart';
import 'receipt_builder.dart';
import 'wifi_printer_service.dart';

abstract class PrintAgentDriver {
  bool get isSupported;
  Future<void> startPollingSafely(String storeId);
  Future<void> stopSafely();
  Future<List<PrintJobAgentResult>> processOnce(String storeId, {int limit});
  Future<PrintResult> testPrintDestination(String destinationId);
}

class PrintJobAgentService implements PrintAgentDriver {
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
  int _lifecycleGeneration = 0;
  String? _activeStoreId;

  @override
  bool get isSupported => !kIsWeb && _printerService.isSupported;

  void startPolling(
    String storeId, {
    Duration interval = const Duration(seconds: 15),
    int limit = 10,
  }) {
    unawaited(startPollingSafely(storeId, interval: interval, limit: limit));
  }

  void stop() {
    unawaited(stopSafely());
  }

  @override
  Future<void> startPollingSafely(
    String storeId, {
    Duration interval = const Duration(seconds: 15),
    int limit = 10,
  }) async {
    final generation = ++_lifecycleGeneration;
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeStoreId = null;
    await _backend.unsubscribeFromJobs();
    if (generation != _lifecycleGeneration || !isSupported) return;

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
    try {
      final jobs = await _backend.claimJobs(storeId, limit: limit);
      final results = <PrintJobAgentResult>[];
      for (final job in jobs) {
        results.add(await _processJob(job));
      }
      return results;
    } finally {
      _isProcessing = false;
    }
  }

  Future<PrintJobAgentResult> _processJob(PrintAgentJob job) async {
    final destinationId = job.destinationId;
    if (destinationId == null || destinationId.isEmpty) {
      await _backend.completeJob(job.id, ok: false, error: 'NO_DESTINATION');
      return PrintJobAgentResult(
        jobId: job.id,
        result: PrintResult.connectionFailed,
        error: 'NO_DESTINATION',
      );
    }

    final destination = await _backend.loadDestination(destinationId);
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

    final bytes = await _buildBytes(job);
    final copyCount = switch (job.ticket.ticket) {
      'floor' || 'confirmation' => 2,
      _ => 1,
    };
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
  Future<PrintResult> testPrintDestination(String destinationId) async {
    if (!isSupported) {
      return PrintResult.notSupported;
    }

    final destination = await _backend.loadDestination(destinationId);
    if (destination == null) {
      return PrintResult.connectionFailed;
    }

    final bytes = await ReceiptBuilder.buildKitchenTicket(
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

    final outcome = await _printToDestination(destination, bytes);
    return outcome.result;
  }

  Future<_EndpointPrintOutcome> _printToDestination(
    PrintDestination destination,
    List<int> bytes, {
    int copyCount = 1,
  }) async {
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
        configuredEndpoints
            .where(
              (endpoint) =>
                  endpoint.isActive &&
                  (capabilities.wiredConnected ||
                      endpoint.type == PrinterEndpointType.wireless),
            )
            .toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
    if (candidates.isEmpty) {
      return const _EndpointPrintOutcome(
        result: PrintResult.noAllowedEndpoint,
        error: 'NO_ALLOWED_PRINTER_ENDPOINT',
      );
    }

    final failures = <String>[];
    for (final endpoint in candidates) {
      var printedCopies = 0;
      var result = PrintResult.success;
      while (printedCopies < copyCount) {
        result = await _printerService.printReceipt(
          endpoint.ip,
          bytes,
          port: endpoint.port,
        );
        if (result != PrintResult.success) break;
        printedCopies++;
      }
      if (printedCopies == copyCount) {
        return _EndpointPrintOutcome(
          result: PrintResult.success,
          endpoint: endpoint,
        );
      }
      failures.add(
        '${endpoint.type.name}@${endpoint.ip}:${endpoint.port}=${result.name}',
      );
      // Do not switch endpoints after a partial multi-copy print; doing so can
      // create an extra first copy at a different physical interface.
      if (printedCopies > 0) {
        return _EndpointPrintOutcome(
          result: result,
          endpoint: endpoint,
          error: 'PARTIAL_PRINT:${failures.join(',')}',
        );
      }
    }

    return _EndpointPrintOutcome(
      result: PrintResult.connectionFailed,
      error: 'ALL_ENDPOINTS_FAILED:${failures.join(',')}',
    );
  }

  Future<List<int>> _buildBytes(PrintAgentJob job) {
    return switch (job.ticket.ticket) {
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
      isService: receipt.isService,
      legalName: receipt.legalName,
      taxCode: receipt.taxCode,
      addressLines: receipt.addressLines,
      receiptNumber: receipt.receiptNumber,
      cashierCode: receipt.cashierCode,
      subtotalAmount: receipt.subtotalAmount,
      discountAmount: receipt.discountAmount,
      receivedAmount: receipt.receivedAmount,
      changeAmount: receipt.changeAmount,
    );
  }
}

abstract class PrintJobBackend {
  Future<List<PrintAgentJob>> claimJobs(String storeId, {int limit = 10});
  Future<PrintDestination?> loadDestination(String destinationId);
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
  }) async {
    final response = await _client.rpc(
      'claim_print_jobs',
      params: {'p_store_id': storeId, 'p_limit': limit},
    );
    final rows = response is List ? response : const <Object?>[];
    return rows
        .whereType<Map>()
        .map((row) => PrintAgentJob.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<PrintDestination?> loadDestination(String destinationId) async {
    final response = await _client
        .from('printer_destinations')
        .select('id, name, ip, port, physical_printer_id')
        .eq('id', destinationId)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    final destination = Map<String, dynamic>.from(response);
    final physicalPrinterId = destination['physical_printer_id']?.toString();
    if (physicalPrinterId != null && physicalPrinterId.isNotEmpty) {
      final endpointRows = await _client
          .from('printer_endpoints')
          .select('id, endpoint_type, ip, port, priority, is_active')
          .eq('physical_printer_id', physicalPrinterId)
          .eq('is_active', true)
          .order('priority');
      destination['endpoints'] = endpointRows;
    }
    return PrintDestination.fromJson(destination);
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
    this.endpoints = const <PrinterEndpoint>[],
  });

  final String id;
  final String name;
  final String ip;
  final int port;
  final List<PrinterEndpoint> endpoints;

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

enum PrinterEndpointType { wired, wireless }

class PrinterEndpoint {
  const PrinterEndpoint({
    required this.id,
    required this.type,
    required this.ip,
    required this.port,
    required this.priority,
    required this.isActive,
  });

  final String id;
  final PrinterEndpointType type;
  final String ip;
  final int port;
  final int priority;
  final bool isActive;

  factory PrinterEndpoint.fromJson(Map<String, dynamic> json) {
    return PrinterEndpoint(
      id: json['id']?.toString() ?? '',
      type: json['endpoint_type']?.toString() == 'wired'
          ? PrinterEndpointType.wired
          : PrinterEndpointType.wireless,
      ip: json['ip']?.toString() ?? '',
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
  });

  final PrintResult result;
  final PrinterEndpoint? endpoint;
  final String? error;
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
