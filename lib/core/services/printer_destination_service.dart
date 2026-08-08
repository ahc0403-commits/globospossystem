import '../../main.dart';

bool isValidPrinterIpv4Address(String value) {
  final parts = value.trim().split('.');
  if (parts.length != 4) return false;

  return parts.every((part) {
    if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    final octet = int.tryParse(part);
    return octet != null && octet >= 0 && octet <= 255;
  });
}

class PrinterDestinationConfig {
  const PrinterDestinationConfig({
    required this.id,
    required this.storeId,
    required this.name,
    required this.ip,
    required this.port,
    required this.purpose,
    required this.isActive,
    this.floorLabel,
    this.physicalPrinterId,
    this.endpoints = const <PrinterEndpointConfig>[],
  });

  final String id;
  final String storeId;
  final String name;
  final String ip;
  final int port;
  final String purpose;
  final String? floorLabel;
  final bool isActive;
  final String? physicalPrinterId;
  final List<PrinterEndpointConfig> endpoints;

  bool get isFloorDestination => purpose == 'floor';

  factory PrinterDestinationConfig.fromJson(
    Map<String, dynamic> json, {
    List<PrinterEndpointConfig> endpoints = const <PrinterEndpointConfig>[],
  }) {
    final portRaw = json['port'];
    return PrinterDestinationConfig(
      id: json['id']?.toString() ?? '',
      storeId: json['restaurant_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      ip: json['ip']?.toString() ?? '',
      port: switch (portRaw) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 9100,
        _ => 9100,
      },
      purpose: json['purpose']?.toString() ?? 'kitchen',
      floorLabel: json['floor_label']?.toString(),
      isActive: json['is_active'] == true,
      physicalPrinterId: json['physical_printer_id']?.toString(),
      endpoints: endpoints,
    );
  }
}

class PrinterEndpointConfig {
  const PrinterEndpointConfig({
    required this.id,
    required this.physicalPrinterId,
    required this.type,
    required this.ip,
    required this.port,
    required this.priority,
    required this.isActive,
  });

  final String id;
  final String physicalPrinterId;
  final String type;
  final String ip;
  final int port;
  final int priority;
  final bool isActive;

  factory PrinterEndpointConfig.fromJson(Map<String, dynamic> json) {
    return PrinterEndpointConfig(
      id: json['id']?.toString() ?? '',
      physicalPrinterId: json['physical_printer_id']?.toString() ?? '',
      type: json['endpoint_type']?.toString() ?? 'wireless',
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

class PrinterDestinationDraft {
  const PrinterDestinationDraft({
    this.id,
    required this.name,
    required this.wiredIp,
    required this.wiredPort,
    required this.wirelessIp,
    required this.wirelessPort,
    required this.purpose,
    this.floorLabel,
    this.isActive = true,
  });

  final String? id;
  final String name;
  final String wiredIp;
  final int wiredPort;
  final String wirelessIp;
  final int wirelessPort;
  final String purpose;
  final String? floorLabel;
  final bool isActive;
}

class PrinterDestinationService {
  Future<List<PrinterDestinationConfig>> fetchDestinations(
    String storeId,
  ) async {
    final rows = await supabase
        .from('printer_destinations')
        .select()
        .eq('restaurant_id', storeId)
        .eq('is_active', true)
        .order('purpose')
        .order('floor_label')
        .order('name');

    final physicalPrinterIds = rows
        .map((row) => row['physical_printer_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final endpointsByPrinter = <String, List<PrinterEndpointConfig>>{};
    if (physicalPrinterIds.isNotEmpty) {
      final endpointRows = await supabase
          .from('printer_endpoints')
          .select()
          .inFilter('physical_printer_id', physicalPrinterIds)
          .eq('is_active', true)
          .order('priority');
      for (final row in endpointRows) {
        final endpoint = PrinterEndpointConfig.fromJson(
          Map<String, dynamic>.from(row),
        );
        endpointsByPrinter
            .putIfAbsent(endpoint.physicalPrinterId, () => [])
            .add(endpoint);
      }
    }

    return rows
        .map<PrinterDestinationConfig>(
          (row) => PrinterDestinationConfig.fromJson(
            Map<String, dynamic>.from(row),
            endpoints:
                endpointsByPrinter[row['physical_printer_id']?.toString()] ??
                const <PrinterEndpointConfig>[],
          ),
        )
        .toList();
  }

  Future<PrinterDestinationConfig> upsertDestination({
    required String storeId,
    required PrinterDestinationDraft draft,
  }) async {
    final response = await supabase.rpc(
      'admin_upsert_printer_destination_v2',
      params: {
        'p_store_id': storeId,
        'p_destination_id': draft.id,
        'p_name': draft.name,
        'p_purpose': draft.purpose,
        'p_floor_label': draft.floorLabel,
        'p_is_active': draft.isActive,
        'p_wired_ip': draft.wiredIp,
        'p_wired_port': draft.wiredPort,
        'p_wireless_ip': draft.wirelessIp,
        'p_wireless_port': draft.wirelessPort,
      },
    );

    return PrinterDestinationConfig.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
  }

  Future<void> deleteDestination({
    required String storeId,
    required String destinationId,
  }) async {
    await supabase.rpc(
      'admin_delete_printer_destination',
      params: {'p_store_id': storeId, 'p_destination_id': destinationId},
    );
  }

  Future<void> enqueueTestPrintJob({
    required String storeId,
    required String destinationId,
  }) async {
    await supabase.rpc(
      'admin_enqueue_printer_test_job',
      params: {'p_store_id': storeId, 'p_destination_id': destinationId},
    );
  }
}

final printerDestinationService = PrinterDestinationService();
