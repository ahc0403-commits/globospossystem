import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hardware/print_agent_coordinator_provider.dart';
import '../../core/hardware/printer_diagnostics.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/services/printer_destination_service.dart';
import '../admin/providers/printer_destinations_provider.dart';
import 'printer_diagnostic_view.dart';

class RegisteredReceiptPrinterPanel extends ConsumerStatefulWidget {
  const RegisteredReceiptPrinterPanel({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<RegisteredReceiptPrinterPanel> createState() =>
      _RegisteredReceiptPrinterPanelState();
}

class _RegisteredReceiptPrinterPanelState
    extends ConsumerState<RegisteredReceiptPrinterPanel> {
  String? _selectedId;
  bool _testing = false;
  int _testGeneration = 0;
  PrinterTestReport? _report;

  Future<void> _test(PrinterDestinationConfig destination, bool print) async {
    if (_testing) return;
    final storeId = widget.storeId;
    final generation = ++_testGeneration;
    setState(() {
      _testing = true;
      _report = null;
    });
    try {
      final report = await ref
          .read(printAgentCoordinatorProvider.notifier)
          .diagnoseDestination(destination.id, printTicket: print);
      if (mounted &&
          widget.storeId == storeId &&
          generation == _testGeneration) {
        setState(() => _report = report);
      }
    } finally {
      if (mounted &&
          widget.storeId == storeId &&
          generation == _testGeneration) {
        setState(() => _testing = false);
      }
    }
  }

  @override
  void didUpdateWidget(RegisteredReceiptPrinterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId) {
      _testGeneration++;
      _selectedId = null;
      _report = null;
      _testing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(printerDestinationsProvider(widget.storeId));
    final destinations = state.destinations
        .where(
          (destination) =>
              destination.storeId == widget.storeId &&
              destination.isActive &&
              destination.purpose == 'receipt',
        )
        .toList();
    final selected =
        destinations.where((d) => d.id == _selectedId).firstOrNull ??
        (destinations.length == 1 ? destinations.single : null);
    final supported = ref
        .read(printAgentCoordinatorProvider.notifier)
        .isSupported;
    return Column(
      key: const Key('registered_receipt_printer_panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.printerRegisteredHint),
        const SizedBox(height: 10),
        if (state.isLoading) const LinearProgressIndicator(),
        if (state.error != null || destinations.isEmpty)
          Text(context.l10n.settingsPrintRoutingUnavailableDetail),
        if (destinations.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey(
              'receipt_choice_${widget.storeId}_${selected?.id}_${destinations.map((d) => d.id).join(',')}',
            ),
            initialValue: selected?.id,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.l10n.settingsReceiptPrinter,
            ),
            items: destinations
                .map((d) => DropdownMenuItem(value: d.id, child: Text(d.name)))
                .toList(),
            onChanged: _testing
                ? null
                : (id) => setState(() {
                    _selectedId = id;
                    _report = null;
                  }),
          ),
          if (selected != null)
            for (final endpoint in selected.endpoints)
              SelectableText(
                endpoint.type == 'usb'
                    ? 'USB · ${endpoint.deviceName}'
                    : '${endpoint.type.toUpperCase()} · ${endpoint.ip}:${endpoint.port}',
              ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                key: const Key('registered_receipt_connection_test'),
                onPressed: selected == null || _testing || !supported
                    ? null
                    : () => _test(selected, false),
                child: Text(context.l10n.settingsConnectionTest),
              ),
              FilledButton(
                key: const Key('registered_receipt_test_print'),
                onPressed: selected == null || _testing || !supported
                    ? null
                    : () => _test(selected, true),
                child: Text(context.l10n.settingsTestPrint),
              ),
            ],
          ),
          if (!supported) Text(context.l10n.settingsPrinterAppOnly),
          if (_testing) const LinearProgressIndicator(),
          if (_report != null) ...[
            const SizedBox(height: 12),
            PrinterDiagnosticView(report: _report!),
          ],
        ],
      ],
    );
  }
}
