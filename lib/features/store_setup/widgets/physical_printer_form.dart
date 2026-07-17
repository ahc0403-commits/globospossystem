import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_models.dart';

class PhysicalPrinterForm extends StatefulWidget {
  const PhysicalPrinterForm({
    super.key,
    required this.title,
    required this.printer,
    required this.onChanged,
  });

  final String title;
  final PhysicalPrinterDraft printer;
  final ValueChanged<PhysicalPrinterDraft> onChanged;

  @override
  State<PhysicalPrinterForm> createState() => _PhysicalPrinterFormState();
}

class _PhysicalPrinterFormState extends State<PhysicalPrinterForm> {
  late final TextEditingController _name;
  late final TextEditingController _ip;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.printer.name);
    _ip = TextEditingController(text: widget.printer.ip);
    _port = TextEditingController(text: '${widget.printer.port}');
  }

  @override
  void didUpdateWidget(covariant PhysicalPrinterForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.printer != widget.printer) {
      if (_name.text != widget.printer.name) _name.text = widget.printer.name;
      if (_ip.text != widget.printer.ip) _ip.text = widget.printer.ip;
      if (_port.text != '${widget.printer.port}') {
        _port.text = '${widget.printer.port}';
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _port.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(
      widget.printer.copyWith(
        name: _name.text,
        ip: _ip.text,
        port: int.tryParse(_port.text) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              onChanged: (_) => _emit(),
              decoration: InputDecoration(
                labelText: context.l10n.storeSetupPrinterName,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: Key('store_setup_ip_${widget.printer.slot.code}'),
              controller: _ip,
              onChanged: (_) => _emit(),
              decoration: InputDecoration(
                labelText: context.l10n.storeSetupPrinterIp,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              onChanged: (_) => _emit(),
              decoration: InputDecoration(
                labelText: context.l10n.storeSetupPrinterPort,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
