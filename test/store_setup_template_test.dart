import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';

void main() {
  test('3-floor template maps four physical printers to five routes', () {
    final printers = StoreOpeningTemplate.defaultPrinters();
    printers[PhysicalPrinterSlot.cashier] =
        printers[PhysicalPrinterSlot.cashier]!.copyWith(ip: '192.168.1.10');
    printers[PhysicalPrinterSlot.kitchen] =
        printers[PhysicalPrinterSlot.kitchen]!.copyWith(ip: '192.168.1.11');
    printers[PhysicalPrinterSlot.floor2] = printers[PhysicalPrinterSlot.floor2]!
        .copyWith(ip: '192.168.1.12');
    printers[PhysicalPrinterSlot.floor3] = printers[PhysicalPrinterSlot.floor3]!
        .copyWith(ip: '192.168.1.13');

    final routes = StoreOpeningTemplate.deriveDestinations(printers);

    expect(routes, hasLength(5));
    expect(routes.map((route) => route.label), [
      'TEST-RECEIPT',
      'TEST-KITCHEN',
      'TEST-1F',
      'TEST-2F',
      'TEST-3F',
    ]);
    expect(routes[0].ip, routes[2].ip);
    expect(routes.map((route) => route.routeKey).toSet(), hasLength(5));
  });

  test('1F can be remapped away from cashier', () {
    final routes = StoreOpeningTemplate.deriveDestinations(
      StoreOpeningTemplate.defaultPrinters(),
      floor1Slot: PhysicalPrinterSlot.floor2,
    );
    expect(
      routes.singleWhere((route) => route.label == 'TEST-1F').physicalSlot,
      PhysicalPrinterSlot.floor2,
    );
  });

  test('numeric, prefixed, and pasted table generation is deterministic', () {
    expect(
      generateNumericTableRange(
        start: 201,
        end: 203,
        floorLabel: ' 2f ',
      ).map((table) => '${table.tableNumber}/${table.floorLabel}'),
      ['201/2F', '202/2F', '203/2F'],
    );
    expect(
      generatePrefixedTableRange(
        prefix: 'a',
        start: 1,
        end: 3,
        floorLabel: '1F',
      ).map((table) => table.tableNumber),
      ['A01', 'A02', 'A03'],
    );
    expect(
      parsePastedTableNumbers(
        value: 'A01, A02\nA03',
        floorLabel: '1F',
      ).map((table) => table.tableNumber),
      ['A01', 'A02', 'A03'],
    );
  });

  test('duplicate table numbers are normalized and visible', () {
    const tables = [
      StoreSetupTableDraft(tableNumber: 'a01', seatCount: 4, floorLabel: '1F'),
      StoreSetupTableDraft(
        tableNumber: ' A01 ',
        seatCount: 4,
        floorLabel: '1F',
      ),
    ];
    expect(duplicateTableNumbers(tables), ['A01']);
  });
}
