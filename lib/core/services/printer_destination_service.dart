import '../../main.dart';

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
  });

  final String id;
  final String storeId;
  final String name;
  final String ip;
  final int port;
  final String purpose;
  final String? floorLabel;
  final bool isActive;

  bool get isFloorDestination => purpose == 'floor';

  factory PrinterDestinationConfig.fromJson(Map<String, dynamic> json) {
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
    );
  }
}

class PrinterDestinationDraft {
  const PrinterDestinationDraft({
    this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.purpose,
    this.floorLabel,
    this.isActive = true,
  });

  final String? id;
  final String name;
  final String ip;
  final int port;
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
        .order('purpose')
        .order('floor_label')
        .order('name');

    return rows
        .map<PrinterDestinationConfig>(
          (row) =>
              PrinterDestinationConfig.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<PrinterDestinationConfig> upsertDestination({
    required String storeId,
    required PrinterDestinationDraft draft,
  }) async {
    final response = await supabase.rpc(
      'admin_upsert_printer_destination',
      params: {
        'p_store_id': storeId,
        'p_destination_id': draft.id,
        'p_name': draft.name,
        'p_ip': draft.ip,
        'p_port': draft.port,
        'p_purpose': draft.purpose,
        'p_floor_label': draft.floorLabel,
        'p_is_active': draft.isActive,
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
