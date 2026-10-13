import 'package:flutter/material.dart';

import '../../core/hardware/printer_diagnostics.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/i18n/locale_extensions.dart';

class PrinterDiagnosticView extends StatelessWidget {
  const PrinterDiagnosticView({super.key, required this.report});

  final PrinterTestReport report;

  String _message(BuildContext context, PrinterOperationStatus status) {
    final l10n = context.l10n;
    if (status.errorCode?.startsWith('USB_') == true ||
        status.errorCode == 'WINDOWS_PRINTER_UNAVAILABLE') {
      return l10n.printerDiagnosticUsb;
    }
    if (status.errorCode == 'PRINTER_CONFIGURATION_INVALID' ||
        status.errorCode == 'DESTINATION_NOT_FOUND' ||
        status.errorCode == 'PRINTER_TEST_SETUP_FAILED') {
      return l10n.printerDiagnosticConfig;
    }
    return switch (status.result) {
      PrintResult.success => l10n.printerDiagnosticAccepted,
      PrintResult.connectionRefused => l10n.printerDiagnosticRefused,
      PrintResult.connectionTimeout => l10n.printerDiagnosticTimeout,
      PrintResult.networkUnreachable => l10n.printerDiagnosticRoute,
      PrintResult.networkUnavailable => l10n.printerDiagnosticOffline,
      PrintResult.notSupported => l10n.settingsPrinterAppOnly,
      PrintResult.noAllowedEndpoint => l10n.printerDiagnosticConfig,
      _ => l10n.printerDiagnosticGeneric,
    };
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('printer_diagnostic_result'),
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (report.attempts.isEmpty)
        Text(
          _message(
            context,
            PrinterOperationStatus(report.result, errorCode: report.errorCode),
          ),
        ),
      for (final attempt in report.attempts) ...[
        SelectableText(
          '${printerEndpointLabel(context, attempt.type)} · ${attempt.address}',
        ),
        Text(_message(context, attempt.status)),
        if (attempt.status.errorCode != null)
          SelectableText(attempt.status.errorCode!),
        const SizedBox(height: 8),
      ],
      if (report.attempts.any((attempt) => attempt.status.mayHavePrinted) &&
          report.result != PrintResult.success)
        Text(context.l10n.printerDiagnosticPartial),
    ],
  );
}

Future<void> showPrinterDiagnosticDialog(
  BuildContext context,
  PrinterTestReport report,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('printer_connection_diagnostic_dialog'),
    title: Text(context.l10n.printerDiagnosticTitle),
    content: SingleChildScrollView(
      child: PrinterDiagnosticView(report: report),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.close),
      ),
    ],
  ),
);

String printerEndpointLabel(BuildContext context, String type) =>
    switch (type) {
      'usb' => context.l10n.settingsPrinterUsb,
      'wired' => context.l10n.settingsPrinterWired,
      'wireless' => context.l10n.settingsPrinterWireless,
      _ => context.l10n.printStationNetwork,
    };
