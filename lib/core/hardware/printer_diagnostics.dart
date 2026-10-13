import 'printer_service.dart';

class PrinterOperationStatus {
  const PrinterOperationStatus(
    this.result, {
    this.errorCode,
    this.mayHavePrinted = false,
  });

  final PrintResult result;
  final String? errorCode;
  final bool mayHavePrinted;
}

class PrinterEndpointAttempt {
  const PrinterEndpointAttempt({
    required this.type,
    required this.address,
    required this.status,
  });

  final String type;
  final String address;
  final PrinterOperationStatus status;
}

class PrinterTestReport {
  const PrinterTestReport({
    required this.result,
    this.attempts = const [],
    this.errorCode,
  });

  final PrintResult result;
  final List<PrinterEndpointAttempt> attempts;
  final String? errorCode;
}

abstract interface class DiagnosticPrinterService {
  Future<PrinterOperationStatus> checkNetworkPrinter(String ip, {int port});
  Future<PrinterOperationStatus> checkUsbPrinter(String printerName);
  Future<PrinterOperationStatus> printNetworkPrinter(
    String ip,
    List<int> bytes, {
    int port,
  });
  Future<PrinterOperationStatus> printWindowsPrinter(
    String printerName,
    List<int> bytes,
  );
}

abstract interface class DiagnosticPrintAgent {
  Future<PrinterTestReport> diagnoseDestination(
    String destinationId, {
    required bool printTicket,
  });
}
