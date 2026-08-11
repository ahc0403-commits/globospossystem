import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('USB printer endpoint is stored, configured, and printed natively', () {
    final migration = File(
      'supabase/migrations/20260811160000_usb_printer_endpoints.sql',
    ).readAsStringSync();
    final destinationService = File(
      'lib/core/services/printer_destination_service.dart',
    ).readAsStringSync();
    final printAgent = File(
      'lib/core/hardware/print_job_agent_service.dart',
    ).readAsStringSync();
    final windowsRunner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    final windowsCmake = File(
      'windows/runner/CMakeLists.txt',
    ).readAsStringSync();

    expect(
      migration,
      contains("endpoint_type IN ('usb', 'wired', 'wireless')"),
    );
    expect(migration, contains('p_usb_printer_name text'));
    expect(migration, contains("'usb', v_usb_printer_name"));
    expect(destinationService, contains('admin_upsert_printer_destination_v3'));
    expect(destinationService, contains("'p_usb_printer_name'"));
    expect(printAgent, contains('PrinterEndpointType.usb'));
    expect(printAgent, contains('printUsbReceipt(endpoint.deviceName, bytes)'));
    expect(windowsRunner, contains('globos/usb_printer'));
    expect(windowsRunner, contains('OpenPrinterW'));
    expect(windowsRunner, contains('WritePrinter'));
    expect(windowsRunner, contains('pDatatype = data_type'));
    expect(windowsCmake, contains('winspool.lib'));
  });

  test('admin and print-station dialogs expose the USB printer name', () {
    final settings = File(
      'lib/features/admin/tabs/settings_tab.dart',
    ).readAsStringSync();
    final station = File(
      'lib/features/print_station/print_station_screen.dart',
    ).readAsStringSync();

    expect(settings, contains("Key('settings_printer_destination_usb_name')"));
    expect(station, contains("Key('print_station_destination_usb_name')"));
    expect(settings, contains('usbPrinterName: usbPrinterName'));
    expect(station, contains('usbPrinterName: usbPrinterName'));
  });
}
