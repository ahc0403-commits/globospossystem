import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_staff_service.dart';

class DirectOrderSettingsScreen extends ConsumerStatefulWidget {
  const DirectOrderSettingsScreen({super.key});

  @override
  ConsumerState<DirectOrderSettingsScreen> createState() =>
      _DirectOrderSettingsScreenState();
}

class _DirectOrderSettingsScreenState
    extends ConsumerState<DirectOrderSettingsScreen> {
  final _slug = TextEditingController();
  final _bankBin = TextEditingController();
  final _bankAccount = TextEditingController();
  final _bankHolder = TextEditingController();
  final _bankLabel = TextEditingController();
  final _minimum = TextEditingController(text: '0');
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  bool _enabled = false;
  bool _paused = false;
  bool _accountingApproved = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  DirectOrderCopy get _copy =>
      DirectOrderCopy(Localizations.localeOf(context).languageCode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in [
      _slug,
      _bankBin,
      _bankAccount,
      _bankHolder,
      _bankLabel,
      _minimum,
      _latitude,
      _longitude,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final storeId = ref.read(authProvider).storeId;
    if (storeId == null) return;
    setState(() => _loading = true);
    try {
      final data = await directOrderStaffService.storefrontConfig(storeId);
      if (!mounted) return;
      _slug.text = data['public_slug']?.toString() ?? '';
      _bankBin.text = data['bank_bin']?.toString() ?? '';
      _bankAccount.text = data['bank_account_number']?.toString() ?? '';
      _bankHolder.text = data['bank_account_holder']?.toString() ?? '';
      _bankLabel.text = data['bank_label']?.toString() ?? '';
      _minimum.text = _textNumber(data['minimum_order_amount'], fallback: '0');
      _latitude.text = _textNumber(data['default_latitude']);
      _longitude.text = _textNumber(data['default_longitude']);
      setState(() {
        _enabled = data['is_enabled'] == true;
        _paused = data['is_paused'] == true;
        _accountingApproved = data['accounting_approved'] == true;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _copy.loadFailed;
      });
    }
  }

  Future<void> _save() async {
    final storeId = ref.read(authProvider).storeId;
    if (storeId == null || _saving) return;
    if (_enabled && !_accountingApproved) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_copy.enableBlocked)));
      return;
    }
    final minimum = double.tryParse(_minimum.text.replaceAll(',', ''));
    if (_slug.text.trim().isEmpty ||
        _bankBin.text.trim().length != 6 ||
        _bankAccount.text.trim().isEmpty ||
        _bankHolder.text.trim().isEmpty ||
        _bankLabel.text.trim().isEmpty ||
        minimum == null ||
        minimum < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_copy.requiredField)));
      return;
    }
    setState(() => _saving = true);
    try {
      await directOrderStaffService.saveStorefrontConfig(
        storeId: storeId,
        slug: _slug.text.trim(),
        enabled: _enabled,
        paused: _paused,
        bankBin: _bankBin.text.trim(),
        bankAccount: _bankAccount.text.trim(),
        bankHolder: _bankHolder.text.trim(),
        bankLabel: _bankLabel.text.trim(),
        minimumOrder: minimum,
        accountingApproved: _accountingApproved,
        latitude: double.tryParse(_latitude.text.trim()),
        longitude: double.tryParse(_longitude.text.trim()),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_copy.saved)));
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_copy.actionFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        title: Text(_copy.settings),
        actions: const [
          LanguageSwitcher(compact: true),
          SizedBox(width: 6),
          Padding(
            padding: EdgeInsets.only(right: 10),
            child: AppNavBar(showLogout: false, showLanguage: false),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(_error!),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: [
                                SwitchListTile(
                                  value: _enabled,
                                  title: Text(_copy.enableStorefront),
                                  secondary: const Icon(Icons.public),
                                  onChanged: (value) {
                                    if (value && !_accountingApproved) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(_copy.enableBlocked),
                                        ),
                                      );
                                      return;
                                    }
                                    setState(() => _enabled = value);
                                  },
                                ),
                                SwitchListTile(
                                  value: _paused,
                                  title: Text(_copy.pauseStorefront),
                                  secondary: const Icon(
                                    Icons.pause_circle_outline,
                                  ),
                                  onChanged: (value) =>
                                      setState(() => _paused = value),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CheckboxListTile(
                                  value: _accountingApproved,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(_copy.accountingApproval),
                                  subtitle: Text(
                                    _copy.accountingApprovalWarning,
                                  ),
                                  onChanged: (value) => setState(() {
                                    _accountingApproved = value ?? false;
                                    if (!_accountingApproved) _enabled = false;
                                  }),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: [
                                _field(_slug, _copy.publicSlug),
                                _field(
                                  _bankBin,
                                  _copy.bankBin,
                                  keyboard: TextInputType.number,
                                ),
                                _field(
                                  _bankAccount,
                                  _copy.bankAccount,
                                  keyboard: TextInputType.number,
                                ),
                                _field(_bankHolder, _copy.bankAccountHolder),
                                _field(_bankLabel, _copy.bankLabel),
                                _field(
                                  _minimum,
                                  _copy.minimumOrder,
                                  keyboard: TextInputType.number,
                                  suffix: 'VND',
                                ),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final fields = [
                                      _field(
                                        _latitude,
                                        _copy.latitude,
                                        keyboard:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                              signed: true,
                                            ),
                                      ),
                                      _field(
                                        _longitude,
                                        _copy.longitude,
                                        keyboard:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                              signed: true,
                                            ),
                                      ),
                                    ];
                                    return constraints.maxWidth >= 620
                                        ? Row(
                                            children: [
                                              Expanded(child: fields[0]),
                                              const SizedBox(width: 12),
                                              Expanded(child: fields[1]),
                                            ],
                                          )
                                        : Column(children: fields);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          alignment: WrapAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _slug.text.trim().isEmpty
                                  ? null
                                  : () => launchUrl(
                                      Uri.parse(
                                        directOrderStaffService.publicUrl(
                                          _slug.text.trim(),
                                        ),
                                      ),
                                      mode: LaunchMode.externalApplication,
                                    ),
                              icon: const Icon(Icons.open_in_new),
                              label: Text(_copy.openCustomerPage),
                            ),
                            FilledButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: const Icon(Icons.save_outlined),
                              label: Text(_copy.save),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
    String? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, suffixText: suffix),
    ),
  );

  String _textNumber(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value.toString());
    if (number == null) return fallback;
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
  }
}
