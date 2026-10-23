import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/payments/vietqr_bank_link.dart';
import 'direct_order_copy.dart';
import 'direct_order_models.dart';

class DirectOrderBankHandoff extends StatefulWidget {
  const DirectOrderBankHandoff({
    super.key,
    required this.bank,
    required this.amount,
    required this.reference,
    required this.returnUri,
    this.launcher,
  });
  final DirectOrderBank bank;
  final int amount;
  final String reference;
  final Uri returnUri;
  final Future<bool> Function(Uri)? launcher;
  @override
  State<DirectOrderBankHandoff> createState() => _DirectOrderBankHandoffState();
}

class _DirectOrderBankHandoffState extends State<DirectOrderBankHandoff> {
  String? _app;
  bool _busy = false, _failed = false;
  Future<void> _open() async {
    final app = _app;
    if (app == null || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final uri = VietQrBankLink.build(
        app: app,
        bankBin: widget.bank.bin,
        accountNumber: widget.bank.accountNumber,
        accountHolder: widget.bank.accountHolder,
        amount: widget.amount,
        reference: widget.reference,
        returnUri: widget.returnUri,
      );
      // Invoke directly during the tap so mobile browsers retain user activation.
      final opened =
          await (widget.launcher?.call(uri) ??
                  launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                    webOnlyWindowName: '_self',
                  ))
              .timeout(const Duration(seconds: 5));
      if (mounted) setState(() => _failed = !opened);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(Localizations.localeOf(context).languageCode);
    if (!VietQrBankLink.recipientCodes.containsKey(widget.bank.bin)) {
      return Text(copy.bankAppFallback);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('direct_bank_app'),
          initialValue: _app,
          isExpanded: true,
          decoration: InputDecoration(labelText: copy.yourBankApp),
          items: [
            for (final app in VietQrBankLink.apps.entries)
              DropdownMenuItem(value: app.key, child: Text(app.value)),
          ],
          onChanged: _busy ? null : (app) => setState(() => _app = app),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('direct_open_bank_app'),
          onPressed: _busy || _app == null ? null : _open,
          icon: const Icon(Icons.open_in_new),
          label: Text(copy.openBankApp),
        ),
        Text(
          _failed ? copy.bankAppFallback : copy.bankAppHelp,
          key: const Key('direct_bank_app_help'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
