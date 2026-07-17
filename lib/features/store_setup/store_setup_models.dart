import 'dart:collection';

class WorkforceAccountTemplate {
  const WorkforceAccountTemplate({
    required this.accountCode,
    required this.accountType,
    required this.role,
    required this.displayName,
    required this.scope,
  });

  final String accountCode;
  final String accountType;
  final String role;
  final String displayName;
  final String scope;

  Map<String, dynamic> toJson() => {
    'account_code': accountCode.trim().toLowerCase(),
    'account_type': accountType,
    'role': role,
    'display_name': displayName.trim(),
    'scope': scope,
  };

  factory WorkforceAccountTemplate.fromJson(Map<String, dynamic> json) =>
      WorkforceAccountTemplate(
        accountCode: json['account_code']?.toString() ?? '',
        accountType: json['account_type']?.toString() ?? 'store_operator',
        role: json['role']?.toString() ?? 'photo_objet_store_operator',
        displayName: json['display_name']?.toString() ?? '',
        scope: json['scope']?.toString() ?? 'store',
      );
}

abstract final class WorkforcePresetCatalog {
  static const andreEmail = 'andre@globos.world';
  static const andreRole = 'super_admin';

  static List<WorkforceAccountTemplate> photo(String shortCode) {
    final short = shortCode.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9_]'),
      '',
    );
    return [
      const WorkforceAccountTemplate(
        accountCode: 'photo_bm1',
        accountType: 'brand_manager',
        role: 'photo_objet_master',
        displayName: 'PHOTO OBJET Brand Manager 1',
        scope: 'brand',
      ),
      const WorkforceAccountTemplate(
        accountCode: 'photo_bm2',
        accountType: 'brand_manager',
        role: 'photo_objet_master',
        displayName: 'PHOTO OBJET Brand Manager 2',
        scope: 'brand',
      ),
      WorkforceAccountTemplate(
        accountCode: '${short.isEmpty ? 'store' : short}_ops1',
        accountType: 'store_operator',
        role: 'photo_objet_store_operator',
        displayName:
            '${short.isEmpty ? 'Store' : short.toUpperCase()} Operator',
        scope: 'store',
      ),
    ];
  }

  static List<WorkforceAccountTemplate> bunsik(String shortCode) {
    final short = shortCode.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9_]'),
      '',
    );
    final prefix = short.isEmpty ? 'store' : short;
    return [
      const WorkforceAccountTemplate(
        accountCode: 'bunsik_bm1',
        accountType: 'brand_manager',
        role: 'brand_admin',
        displayName: 'Bunsik Brand Manager',
        scope: 'brand',
      ),
      const WorkforceAccountTemplate(
        accountCode: 'bunsik_sm1',
        accountType: 'store_manager',
        role: 'store_admin',
        displayName: 'Bunsik Store Manager',
        scope: 'store',
      ),
      WorkforceAccountTemplate(
        accountCode: '${prefix}_pos1',
        accountType: 'device_pos',
        role: 'cashier',
        displayName: '${prefix.toUpperCase()} POS',
        scope: 'store',
      ),
      WorkforceAccountTemplate(
        accountCode: '${prefix}_tab1',
        accountType: 'device_tablet',
        role: 'cashier',
        displayName: '${prefix.toUpperCase()} Tablet',
        scope: 'store',
      ),
      WorkforceAccountTemplate(
        accountCode: '${prefix}_kit1',
        accountType: 'device_kitchen',
        role: 'kitchen',
        displayName: '${prefix.toUpperCase()} Kitchen',
        scope: 'store',
      ),
    ];
  }
}

enum PhysicalPrinterSlot { cashier, kitchen, floor2, floor3 }

extension PhysicalPrinterSlotCode on PhysicalPrinterSlot {
  String get code => switch (this) {
    PhysicalPrinterSlot.cashier => 'cashier',
    PhysicalPrinterSlot.kitchen => 'kitchen',
    PhysicalPrinterSlot.floor2 => 'floor2',
    PhysicalPrinterSlot.floor3 => 'floor3',
  };
}

class PhysicalPrinterDraft {
  const PhysicalPrinterDraft({
    required this.slot,
    required this.name,
    this.ip = '',
    this.port = 9100,
  });

  final PhysicalPrinterSlot slot;
  final String name;
  final String ip;
  final int port;

  PhysicalPrinterDraft copyWith({String? name, String? ip, int? port}) {
    return PhysicalPrinterDraft(
      slot: slot,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
    );
  }
}

class StoreSetupTableDraft {
  const StoreSetupTableDraft({
    required this.tableNumber,
    required this.seatCount,
    required this.floorLabel,
    this.existingId,
    this.existingStatus,
  });

  final String tableNumber;
  final int seatCount;
  final String floorLabel;
  final String? existingId;
  final String? existingStatus;

  bool get isProtected =>
      existingStatus == 'occupied' || existingStatus == 'reserved';

  StoreSetupTableDraft copyWith({
    String? tableNumber,
    int? seatCount,
    String? floorLabel,
  }) {
    return StoreSetupTableDraft(
      tableNumber: tableNumber ?? this.tableNumber,
      seatCount: seatCount ?? this.seatCount,
      floorLabel: floorLabel ?? this.floorLabel,
      existingId: existingId,
      existingStatus: existingStatus,
    );
  }

  Map<String, dynamic> toJson() => {
    'table_number': tableNumber.trim(),
    'seat_count': seatCount,
    'floor_label': normalizeFloorLabel(floorLabel),
  };

  factory StoreSetupTableDraft.fromJson(Map<String, dynamic> json) {
    return StoreSetupTableDraft(
      tableNumber: json['table_number']?.toString() ?? '',
      seatCount: switch (json['seat_count']) {
        int value => value,
        num value => value.toInt(),
        _ => 4,
      },
      floorLabel: normalizeFloorLabel(json['floor_label']?.toString() ?? '1F'),
      existingId: json['id']?.toString(),
      existingStatus: json['status']?.toString().toLowerCase(),
    );
  }
}

class LogicalDestinationDraft {
  const LogicalDestinationDraft({
    required this.label,
    required this.name,
    required this.ip,
    required this.port,
    required this.purpose,
    this.floorLabel,
    required this.physicalSlot,
    this.existingId,
  });

  final String label;
  final String name;
  final String ip;
  final int port;
  final String purpose;
  final String? floorLabel;
  final PhysicalPrinterSlot physicalSlot;
  final String? existingId;

  String get routeKey =>
      '$purpose/${purpose == 'floor' ? normalizeFloorLabel(floorLabel ?? '') : ''}';

  Map<String, dynamic> toJson() => {
    'name': name.trim(),
    'ip': ip.trim(),
    'port': port,
    'purpose': purpose,
    'floor_label': purpose == 'floor'
        ? normalizeFloorLabel(floorLabel ?? '')
        : null,
  };
}

class StoreOpeningTemplate {
  const StoreOpeningTemplate._();

  static const id = 'three_floors_four_printers';
  static const floors = ['1F', '2F', '3F'];

  static Map<PhysicalPrinterSlot, PhysicalPrinterDraft> defaultPrinters() => {
    PhysicalPrinterSlot.cashier: const PhysicalPrinterDraft(
      slot: PhysicalPrinterSlot.cashier,
      name: 'Cashier',
    ),
    PhysicalPrinterSlot.kitchen: const PhysicalPrinterDraft(
      slot: PhysicalPrinterSlot.kitchen,
      name: 'Kitchen',
    ),
    PhysicalPrinterSlot.floor2: const PhysicalPrinterDraft(
      slot: PhysicalPrinterSlot.floor2,
      name: '2F',
    ),
    PhysicalPrinterSlot.floor3: const PhysicalPrinterDraft(
      slot: PhysicalPrinterSlot.floor3,
      name: '3F',
    ),
  };

  static List<LogicalDestinationDraft> deriveDestinations(
    Map<PhysicalPrinterSlot, PhysicalPrinterDraft> printers, {
    PhysicalPrinterSlot floor1Slot = PhysicalPrinterSlot.cashier,
  }) {
    PhysicalPrinterDraft printer(PhysicalPrinterSlot slot) => printers[slot]!;

    LogicalDestinationDraft route({
      required String label,
      required String name,
      required String purpose,
      String? floor,
      required PhysicalPrinterSlot slot,
    }) {
      final target = printer(slot);
      return LogicalDestinationDraft(
        label: label,
        name: name,
        ip: target.ip,
        port: target.port,
        purpose: purpose,
        floorLabel: floor,
        physicalSlot: slot,
      );
    }

    return [
      route(
        label: 'TEST-RECEIPT',
        name: '${printer(PhysicalPrinterSlot.cashier).name} Receipt',
        purpose: 'receipt',
        slot: PhysicalPrinterSlot.cashier,
      ),
      route(
        label: 'TEST-KITCHEN',
        name: printer(PhysicalPrinterSlot.kitchen).name,
        purpose: 'kitchen',
        slot: PhysicalPrinterSlot.kitchen,
      ),
      route(
        label: 'TEST-1F',
        name: '1F via ${printer(floor1Slot).name}',
        purpose: 'floor',
        floor: '1F',
        slot: floor1Slot,
      ),
      route(
        label: 'TEST-2F',
        name: printer(PhysicalPrinterSlot.floor2).name,
        purpose: 'floor',
        floor: '2F',
        slot: PhysicalPrinterSlot.floor2,
      ),
      route(
        label: 'TEST-3F',
        name: printer(PhysicalPrinterSlot.floor3).name,
        purpose: 'floor',
        floor: '3F',
        slot: PhysicalPrinterSlot.floor3,
      ),
    ];
  }
}

String normalizeFloorLabel(String value) => value.trim().toUpperCase();

List<StoreSetupTableDraft> generateNumericTableRange({
  required int start,
  required int end,
  required String floorLabel,
  int seatCount = 4,
}) {
  if (start < 0 || end < start || end - start > 499) {
    throw const FormatException('STORE_SETUP_TABLE_RANGE_INVALID');
  }
  return [
    for (var number = start; number <= end; number++)
      StoreSetupTableDraft(
        tableNumber: '$number',
        seatCount: seatCount,
        floorLabel: normalizeFloorLabel(floorLabel),
      ),
  ];
}

List<StoreSetupTableDraft> generatePrefixedTableRange({
  required String prefix,
  required int start,
  required int end,
  int padWidth = 2,
  required String floorLabel,
  int seatCount = 4,
}) {
  final normalizedPrefix = prefix.trim().toUpperCase();
  if (normalizedPrefix.isEmpty ||
      !RegExp(r'^[A-Z0-9_-]+$').hasMatch(normalizedPrefix)) {
    throw const FormatException('STORE_SETUP_TABLE_PREFIX_INVALID');
  }
  return [
    for (final table in generateNumericTableRange(
      start: start,
      end: end,
      floorLabel: floorLabel,
      seatCount: seatCount,
    ))
      table.copyWith(
        tableNumber:
            '$normalizedPrefix${int.parse(table.tableNumber).toString().padLeft(padWidth, '0')}',
      ),
  ];
}

List<StoreSetupTableDraft> parsePastedTableNumbers({
  required String value,
  required String floorLabel,
  int seatCount = 4,
}) {
  return value
      .split(RegExp(r'[\s,;]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .map(
        (tableNumber) => StoreSetupTableDraft(
          tableNumber: tableNumber,
          seatCount: seatCount,
          floorLabel: normalizeFloorLabel(floorLabel),
        ),
      )
      .toList(growable: false);
}

List<String> duplicateTableNumbers(Iterable<StoreSetupTableDraft> tables) {
  final seen = <String>{};
  final duplicates = SplayTreeSet<String>();
  for (final table in tables) {
    final key = table.tableNumber.trim().toUpperCase();
    if (!seen.add(key)) duplicates.add(key);
  }
  return duplicates.toList(growable: false);
}

class StoreOpeningDraft {
  const StoreOpeningDraft({
    required this.storeId,
    this.templateId = StoreOpeningTemplate.id,
    this.floors = StoreOpeningTemplate.floors,
    this.tables = const [],
    required this.printers,
    this.floor1Slot = PhysicalPrinterSlot.cashier,
  });

  final String storeId;
  final String templateId;
  final List<String> floors;
  final List<StoreSetupTableDraft> tables;
  final Map<PhysicalPrinterSlot, PhysicalPrinterDraft> printers;
  final PhysicalPrinterSlot floor1Slot;

  List<LogicalDestinationDraft> get destinations =>
      StoreOpeningTemplate.deriveDestinations(printers, floor1Slot: floor1Slot);

  StoreOpeningDraft copyWith({
    List<String>? floors,
    List<StoreSetupTableDraft>? tables,
    Map<PhysicalPrinterSlot, PhysicalPrinterDraft>? printers,
    PhysicalPrinterSlot? floor1Slot,
  }) {
    return StoreOpeningDraft(
      storeId: storeId,
      templateId: templateId,
      floors: floors ?? this.floors,
      tables: tables ?? this.tables,
      printers: printers ?? this.printers,
      floor1Slot: floor1Slot ?? this.floor1Slot,
    );
  }
}

class StoreSetupValidationResult {
  const StoreSetupValidationResult({
    required this.valid,
    this.errors = const [],
    this.warnings = const [],
    this.plan = const {},
  });

  final bool valid;
  final List<String> errors;
  final List<String> warnings;
  final Map<String, int> plan;

  factory StoreSetupValidationResult.fromJson(Map<String, dynamic> json) {
    final planJson = json['plan'] is Map
        ? Map<String, dynamic>.from(json['plan'] as Map)
        : const <String, dynamic>{};
    return StoreSetupValidationResult(
      valid: json['valid'] == true,
      errors: (json['errors'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      warnings: (json['warnings'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      plan: planJson.map(
        (key, value) => MapEntry(key, value is num ? value.toInt() : 0),
      ),
    );
  }
}

class StoreSetupTestJob {
  const StoreSetupTestJob({
    required this.label,
    required this.destinationId,
    required this.jobId,
    this.status = 'pending',
    this.error,
    this.physicallyConfirmed = false,
  });

  final String label;
  final String destinationId;
  final String jobId;
  final String status;
  final String? error;
  final bool physicallyConfirmed;

  bool get isTerminal => status == 'done' || status == 'failed';

  StoreSetupTestJob copyWith({
    String? status,
    String? error,
    bool? physicallyConfirmed,
  }) {
    return StoreSetupTestJob(
      label: label,
      destinationId: destinationId,
      jobId: jobId,
      status: status ?? this.status,
      error: error ?? this.error,
      physicallyConfirmed: physicallyConfirmed ?? this.physicallyConfirmed,
    );
  }
}
