import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/live_sync_scope.dart';
import 'printer_service.dart';
import 'receipt_builder.dart';
import 'wifi_printer_service.dart';

class PrintJobAgentService {
  PrintJobAgentService({
    PrintJobBackend? backend,
    PrinterService? printerService,
  }) : _backend = backend ?? SupabasePrintJobBackend(Supabase.instance.client),
       _printerService = printerService ?? createPrinterService();

  final PrintJobBackend _backend;
  final PrinterService _printerService;
  Timer? _pollTimer;
  bool _isProcessing = false;

  bool get isSupported => !kIsWeb && _printerService.isSupported;

  void startPolling(
    String storeId, {
    Duration interval = const Duration(seconds: 15),
    int limit = 10,
  }) {
    stop();
    if (!isSupported) {
      return;
    }
    unawaited(
      _backend.subscribeToJobs(
        storeId,
        () => unawaited(processOnce(storeId, limit: limit)),
      ),
    );
    unawaited(processOnce(storeId, limit: limit));
    _pollTimer = Timer.periodic(interval, (_) {
      unawaited(processOnce(storeId, limit: limit));
    });
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    unawaited(_backend.unsubscribeFromJobs());
  }

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

    final bytes = await _buildBytes(job.ticket);
    final result = await _printerService.printReceipt(
      destination.ip,
      bytes,
      port: destination.port,
    );
    final ok = result == PrintResult.success;
    await _backend.completeJob(job.id, ok: ok, error: ok ? null : result.name);
    return PrintJobAgentResult(
      jobId: job.id,
      result: result,
      error: ok ? null : result.name,
    );
  }

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
        floorLabel: 'TEST',
        tableNumber: destination.name.isEmpty ? 'PRINTER' : destination.name,
        ticketCode: 'TEST',
        batchNo: 1,
        printedReason: 'initial',
        printedAt: DateTime.now().toIso8601String(),
        items: const [
          PrintTicketItem(label: 'Printer route test', quantity: 1),
        ],
        orderNotes: 'Print station test',
      ),
    );

    return _printerService.printReceipt(
      destination.ip,
      bytes,
      port: destination.port,
    );
  }

  Future<List<int>> _buildBytes(PrintTicket ticket) {
    return switch (ticket.ticket) {
      'floor' => ReceiptBuilder.buildFloorTicket(ticket),
      'tray' => ReceiptBuilder.buildTrayLabel(ticket),
      _ => ReceiptBuilder.buildKitchenTicket(ticket),
    };
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
        .select('id, name, ip, port')
        .eq('id', destinationId)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return PrintDestination.fromJson(Map<String, dynamic>.from(response));
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
  });

  final String id;
  final String? destinationId;
  final PrintTicket ticket;

  factory PrintAgentJob.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    return PrintAgentJob(
      id: json['id'].toString(),
      destinationId: json['destination_id']?.toString(),
      ticket: PrintTicket.fromPayload(
        payload is Map<String, dynamic>
            ? payload
            : Map<String, dynamic>.from(payload as Map),
      ),
    );
  }
}

class PrintDestination {
  const PrintDestination({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
  });

  final String id;
  final String name;
  final String ip;
  final int port;

  factory PrintDestination.fromJson(Map<String, dynamic> json) {
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
    );
  }
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
