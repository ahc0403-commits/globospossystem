import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_models.dart';

class PhysicalPrinterForm extends StatefulWidget {
  const PhysicalPrinterForm({
    super.key,
    required this.title,
    required this.printer,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final PhysicalPrinterDraft printer;
  final ValueChanged<PhysicalPrinterDraft> onChanged;
  final bool enabled;

  @override
  State<PhysicalPrinterForm> createState() => _PhysicalPrinterFormState();
}

class _PhysicalPrinterFormState extends State<PhysicalPrinterForm> {
  late final TextEditingController _name;
  late final TextEditingController _ip;
  late final TextEditingController _port;
  late final TextEditingController _usbName;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.printer.name);
    _ip = TextEditingController(text: widget.printer.ip);
    _port = TextEditingController(text: '${widget.printer.port}');
    _usbName = TextEditingController(text: widget.printer.usbPrinterName);
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
      if (_usbName.text != widget.printer.usbPrinterName) {
        _usbName.text = widget.printer.usbPrinterName;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _port.dispose();
    _usbName.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(
      widget.printer.copyWith(
        name: _name.text,
        ip: _ip.text,
        port: int.tryParse(_port.text) ?? 0,
        usbPrinterName: _usbName.text,
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
              enabled: widget.enabled,
              onChanged: (_) => _emit(),
              decoration: InputDecoration(
                labelText: context.l10n.storeSetupPrinterName,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<SetupPrinterConnection>(
              key: Key('store_setup_connection_${widget.printer.slot.code}'),
              initialValue: widget.printer.connection,
              decoration: InputDecoration(
                labelText: context.l10n.storeSetupConnection,
              ),
              items: [
                DropdownMenuItem(
                  value: SetupPrinterConnection.wired,
                  child: Text(context.l10n.settingsPrinterWired),
                ),
                DropdownMenuItem(
                  value: SetupPrinterConnection.wireless,
                  child: Text(context.l10n.settingsPrinterWireless),
                ),
                DropdownMenuItem(
                  value: SetupPrinterConnection.usb,
                  child: Text(context.l10n.settingsPrinterUsb),
                ),
              ],
              onChanged: !widget.enabled
                  ? null
                  : (value) {
                      if (value != null) {
                        widget.onChanged(
                          widget.printer.copyWith(connection: value),
                        );
                      }
                    },
            ),
            const SizedBox(height: 8),
            if (widget.printer.connection == SetupPrinterConnection.usb)
              TextField(
                key: Key('store_setup_usb_${widget.printer.slot.code}'),
                controller: _usbName,
                enabled: widget.enabled,
                onChanged: (_) => _emit(),
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupUsbName,
                  helperText: context.l10n.storeSetupUsbHelp,
                  helperMaxLines: 3,
                ),
              )
            else ...[
              TextField(
                key: Key('store_setup_ip_${widget.printer.slot.code}'),
                controller: _ip,
                enabled: widget.enabled,
                onChanged: (_) => _emit(),
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupPrinterIp,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _port,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                onChanged: (_) => _emit(),
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupPrinterPort,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
