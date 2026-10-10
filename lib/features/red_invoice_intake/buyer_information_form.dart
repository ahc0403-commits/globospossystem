import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/services/company_tax_lookup_service.dart';
import 'buyer_number.dart';
import 'company_lookup_copy.dart';

const buyerInformationKeys = [
  'buyer_number_value',
  'buyer_legal_name',
  'buyer_full_name',
  'buyer_address',
  'buyer_email',
  'buyer_phone',
  'buyer_email_cc',
  'buyer_unit_code',
  'buyer_id',
  'source_note',
];

class BuyerInformationController {
  BuyerInformationController(
    Map<String, dynamic> initial, {
    this.confirm = true,
  }) : type = BuyerNumberType.parse(initial['buyer_number_type']?.toString()),
       fields = {
         for (final key in buyerInformationKeys)
           key: TextEditingController(text: initial[key]?.toString() ?? ''),
       };
  final key = GlobalKey<FormState>();
  final numberFocus = FocusNode();
  final Map<String, TextEditingController> fields;
  BuyerNumberType type;
  bool confirm;
  String? serverNumberError;
  Map<String, dynamic> get patch => {
    'buyer_number_type': type.value,
    for (final entry in fields.entries) entry.key: entry.value.text.trim(),
  };
  bool validate() {
    final valid = key.currentState?.validate() ?? false;
    if (!valid &&
        (serverNumberError != null ||
            validateBuyerNumber(type, fields['buyer_number_value']!.text) !=
                null)) {
      numberFocus.requestFocus();
    }
    return valid;
  }

  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    numberFocus.dispose();
  }
}

class BuyerInformationFields extends StatefulWidget {
  const BuyerInformationFields({
    super.key,
    required this.controller,
    this.storeId,
    this.lookupService,
  });
  final BuyerInformationController controller;
  final String? storeId;
  final CompanyTaxLookupService? lookupService;
  @override
  State<BuyerInformationFields> createState() => _BuyerInformationFieldsState();
}

class _BuyerInformationFieldsState extends State<BuyerInformationFields> {
  CompanyTaxLookupService? _service;
  CompanyLookupResult? _lookupResult;
  String? _providedName, _filledName, _attemptedKey;
  late String _lastNumber, _lastName;
  bool _lookingUp = false, _applying = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _attach();
    _setService();
  }

  void _setService() {
    _service?.removeListener(_sessionChanged);
    _service = widget.storeId == null ? null : widget.lookupService;
    _service?.addListener(_sessionChanged);
  }

  void _attach() {
    final c = widget.controller;
    _lastNumber = c.fields['buyer_number_value']!.text;
    _lastName = c.fields['buyer_legal_name']!.text;
    c.fields['buyer_number_value']!.addListener(_numberChanged);
    c.fields['buyer_legal_name']!.addListener(_nameChanged);
    c.numberFocus.addListener(_numberFocusChanged);
  }

  void _detach(BuyerInformationController c) {
    c.fields['buyer_number_value']!.removeListener(_numberChanged);
    c.fields['buyer_legal_name']!.removeListener(_nameChanged);
    c.numberFocus.removeListener(_numberFocusChanged);
  }

  @override
  void didUpdateWidget(BuyerInformationFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _providedName = null;
      _filledName = null;
      _attach();
      _invalidate();
    }
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.lookupService != widget.lookupService) {
      _invalidate(restoreName: true);
      _setService();
    }
  }

  void _numberChanged() {
    final text = widget.controller.fields['buyer_number_value']!.text;
    if (text == _lastNumber) return;
    _lastNumber = text;
    _invalidate(restoreName: true);
  }

  void _nameChanged() {
    final text = widget.controller.fields['buyer_legal_name']!.text;
    if (text == _lastName) return;
    _lastName = text;
    if (!_applying) _invalidate();
  }

  void _sessionChanged() => _invalidate(restoreName: true);

  void _invalidate({bool restoreName = false}) {
    if (restoreName &&
        _providedName != null &&
        widget.controller.fields['buyer_legal_name']!.text == _filledName) {
      _applying = true;
      widget.controller.fields['buyer_legal_name']!.text = _providedName!;
      _applying = false;
    }
    _revision++;
    _lookupResult = null;
    _providedName = null;
    _filledName = null;
    _attemptedKey = null;
    _lookingUp = false;
    if (mounted) setState(() {});
  }

  void _numberFocusChanged() {
    if (!widget.controller.numberFocus.hasFocus) {
      unawaited(_lookup(manual: false));
    }
  }

  Future<void> _lookup({required bool manual}) async {
    final c = widget.controller;
    final store = widget.storeId;
    if (store == null || _lookingUp || c.type != BuyerNumberType.vnTax) {
      return;
    }
    final code = c.fields['buyer_number_value']!.text.trim();
    final issue = validateBuyerNumber(c.type, code);
    if (issue != null) {
      if (manual) {
        setState(
          () => c.serverNumberError = BuyerNumberCopy(
            Localizations.localeOf(context).languageCode,
          ).error(issue),
        );
        c.numberFocus.requestFocus();
      }
      return;
    }
    final service = _service ??= companyTaxLookupService;
    service.removeListener(_sessionChanged);
    service.addListener(_sessionChanged);
    final session = service.sessionScope;
    final attempt = '$session|$store|$code';
    if (!manual && _attemptedKey == attempt) return;
    _attemptedKey = attempt;
    final nameBefore = c.fields['buyer_legal_name']!.text;
    _providedName ??= nameBefore;
    final revision = ++_revision;
    setState(() {
      _lookingUp = true;
      _lookupResult = null;
    });
    final result = await service.lookup(storeId: store, taxCode: code);
    if (!mounted ||
        revision != _revision ||
        widget.controller != c ||
        widget.storeId != store ||
        c.type != BuyerNumberType.vnTax ||
        c.fields['buyer_number_value']!.text.trim() != code ||
        c.fields['buyer_legal_name']!.text != nameBefore ||
        service.sessionScope != session) {
      if (mounted && revision == _revision) _invalidate(restoreName: true);
      return;
    }
    if (result.outcome == CompanyLookupOutcome.success) {
      _applying = true;
      c.fields['buyer_legal_name']!.text = result.companyName!;
      _applying = false;
      _filledName = result.companyName;
    }
    setState(() {
      _lookupResult = result;
      _lookingUp = false;
    });
  }

  Widget _lookupPanel(CompanyLookupCopy copy) {
    final result = _lookupResult;
    final success = result?.outcome == CompanyLookupOutcome.success;
    final original = _providedName ?? '';
    final differs =
        success &&
        original.trim().isNotEmpty &&
        !companyNamesMatch(original, result!.companyName!);
    final message = _lookingUp
        ? copy.loading
        : success
        ? original.trim().isEmpty
              ? copy.filled
              : differs
              ? copy.mismatch
              : copy.matched
        : result == null
        ? null
        : copy.failure(result.outcome);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('pos_company_lookup'),
            onPressed: _lookingUp ? null : () => _lookup(manual: true),
            icon: _lookingUp
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search),
            label: Text(copy.lookup),
          ),
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(message, key: const Key('pos_company_lookup_status')),
          ),
        if (differs) ...[
          Text(
            '${copy.provided}: $original',
            key: const Key('pos_company_provided_name'),
          ),
          Text(
            '${copy.found}: ${result.companyName}',
            key: const Key('pos_company_found_name'),
          ),
        ],
        if (success)
          Text(copy.source, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  @override
  void dispose() {
    _revision++;
    _detach(widget.controller);
    _service?.removeListener(_sessionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final copy = BuyerNumberCopy(Localizations.localeOf(context).languageCode);
    final lookupCopy = CompanyLookupCopy(
      Localizations.localeOf(context).languageCode,
    );
    final l10n = context.l10n;
    final personal = {
      BuyerNumberType.personal,
      BuyerNumberType.passport,
    }.contains(c.type);
    String label(String key) => switch (key) {
      'buyer_number_value' => copy.label(c.type),
      'buyer_legal_name' => l10n.redInvoiceCompanyName,
      'buyer_full_name' => copy.pick('구매자명', 'Tên người mua', 'Buyer name'),
      'buyer_address' => l10n.address,
      'buyer_email' => l10n.redInvoiceEmailRequiredLabel,
      'buyer_phone' => l10n.redInvoicePhone,
      'buyer_email_cc' => copy.pick('참조 이메일', 'Email CC', 'CC email'),
      'buyer_unit_code' => copy.pick('단위코드', 'Mã đơn vị', 'Unit code'),
      'buyer_id' => copy.pick(
        '추가 구매자 CCCD (선택)',
        'CCCD người mua bổ sung (tùy chọn)',
        'Additional buyer CCCD (optional)',
      ),
      _ => l10n.redInvoiceSourceNote,
    };
    return Form(
      key: c.key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<BuyerNumberType>(
            key: const Key('pos_buyer_number_type'),
            initialValue: c.type,
            isExpanded: true,
            decoration: InputDecoration(labelText: copy.type),
            items: [
              for (final type in BuyerNumberType.values)
                DropdownMenuItem(value: type, child: Text(copy.label(type))),
            ],
            onChanged: (value) => setState(() {
              _invalidate(restoreName: true);
              c.type = value!;
              c.serverNumberError = null;
            }),
          ),
          const SizedBox(height: 12),
          for (final key in buyerInformationKeys)
            if (key != 'buyer_id' || !personal)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      key: Key('pos_$key'),
                      controller: c.fields[key],
                      forceErrorText: key == 'buyer_number_value'
                          ? c.serverNumberError
                          : null,
                      focusNode: key == 'buyer_number_value'
                          ? c.numberFocus
                          : null,
                      keyboardType: key.contains('email')
                          ? TextInputType.emailAddress
                          : key == 'buyer_phone'
                          ? TextInputType.phone
                          : TextInputType.text,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      maxLines: key == 'buyer_address' || key == 'source_note'
                          ? 3
                          : 1,
                      decoration: InputDecoration(
                        labelText: label(key),
                        helperText: key == 'buyer_number_value'
                            ? copy.formatOnly
                            : null,
                      ),
                      onChanged: (_) {
                        if (key == 'buyer_number_value') {
                          c.serverNumberError = null;
                        }
                      },
                      onFieldSubmitted: (_) =>
                          key == 'buyer_number_value' &&
                              widget.storeId != null &&
                              c.type == BuyerNumberType.vnTax
                          ? unawaited(_lookup(manual: true))
                          : c.validate(),
                      validator: (raw) {
                        final value = raw?.trim() ?? '';
                        if (key == 'buyer_number_value' && c.confirm) {
                          final issue = validateBuyerNumber(c.type, value);
                          return c.serverNumberError ??
                              (issue == null ? null : copy.error(issue));
                        }
                        if (c.confirm &&
                            key == 'buyer_id' &&
                            value.isNotEmpty &&
                            {
                              BuyerNumberType.vnTax,
                              BuyerNumberType.household,
                            }.contains(c.type)) {
                          final issue = validateBuyerNumber(
                            BuyerNumberType.personal,
                            value,
                          );
                          if (issue != null) return copy.error(issue);
                        }
                        if (c.confirm &&
                            {
                              personal ? 'buyer_full_name' : 'buyer_legal_name',
                              'buyer_address',
                              'buyer_email',
                              'buyer_phone',
                            }.contains(key) &&
                            value.isEmpty) {
                          return l10n.redInvoiceRequiredField;
                        }
                        if (key == 'buyer_email' &&
                            value.isNotEmpty &&
                            !value.contains('@')) {
                          return l10n.redInvoiceInvalidEmail;
                        }
                        final limit =
                            key == 'buyer_number_value' || key == 'buyer_id'
                            ? 64
                            : key == 'buyer_phone'
                            ? 30
                            : key == 'buyer_email'
                            ? 254
                            : key == 'buyer_email_cc'
                            ? 1000
                            : key == 'buyer_unit_code'
                            ? 100
                            : key == 'buyer_legal_name' ||
                                  key == 'buyer_full_name'
                            ? 300
                            : 500;
                        if (value.length > limit) {
                          return copy.pick(
                            '최대 $limit자까지 입력할 수 있습니다.',
                            'Tối đa $limit ký tự.',
                            'Use at most $limit characters.',
                          );
                        }
                        return null;
                      },
                    ),
                    if (key == 'buyer_number_value' &&
                        widget.storeId != null &&
                        c.type == BuyerNumberType.vnTax)
                      _lookupPanel(lookupCopy),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

Future<Map<String, dynamic>?> showBuyerInformationDialog(
  BuildContext context, {
  required Map<String, dynamic> initial,
  String? storeId,
  CompanyTaxLookupService? lookupService,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
  bool confirm = true,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _BuyerInformationDialog(
    initial: initial,
    storeId: storeId,
    lookupService: lookupService,
    onSave: onSave,
    confirm: confirm,
  ),
);

class _BuyerInformationDialog extends StatefulWidget {
  const _BuyerInformationDialog({
    required this.initial,
    this.storeId,
    this.lookupService,
    required this.onSave,
    required this.confirm,
  });
  final Map<String, dynamic> initial;
  final String? storeId;
  final CompanyTaxLookupService? lookupService;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave;
  final bool confirm;
  @override
  State<_BuyerInformationDialog> createState() =>
      _BuyerInformationDialogState();
}

class _BuyerInformationDialogState extends State<_BuyerInformationDialog> {
  late final controller = BuyerInformationController(
    widget.initial,
    confirm: widget.confirm,
  );
  bool saving = false;
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (saving || !controller.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await widget.onSave(controller.patch);
      if (mounted) Navigator.pop(context, result);
    } catch (failure) {
      if (!mounted) return;
      final copy = BuyerNumberCopy(
        Localizations.localeOf(context).languageCode,
      );
      setState(() {
        if (failure is PostgrestException &&
            failure.message == 'POS_BUYER_NUMBER_INVALID') {
          try {
            final detail = jsonDecode(failure.details.toString()) as Map;
            controller.serverNumberError = copy.error(
              BuyerNumberIssue(
                detail['code'].toString(),
                actual: detail['actual'] as int?,
                left: detail['left'] as int?,
                right: detail['right'] as int?,
              ),
            );
          } catch (_) {
            controller.serverNumberError = copy.pick(
              '번호를 확인해 주세요.',
              'Vui lòng kiểm tra số.',
              'Check the number.',
            );
          }
          controller.validate();
        }
        error =
            failure is PostgrestException &&
                failure.message == 'POS_BUYER_CHANGED'
            ? copy.pick(
                '다른 직원이 정보를 수정했습니다. 창을 닫고 최신 정보를 다시 불러와 주세요.',
                'Nhân viên khác đã sửa thông tin. Đóng cửa sổ và tải lại dữ liệu mới.',
                'Another employee changed this information. Close and reload the latest record.',
              )
            : copy.pick(
                '저장하지 못했습니다. 입력한 내용은 유지됩니다.',
                'Không lưu được. Nội dung đã nhập được giữ lại.',
                'Save failed. Your entries have been retained.',
              );
      });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BuyerInformationFields(
              controller: controller,
              storeId: widget.storeId,
              lookupService: widget.lookupService,
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
    final actions = <Widget>[
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        key: const Key('pos_buyer_save'),
        onPressed: saving ? null : _save,
        child: Text(context.l10n.save),
      ),
    ];
    if (MediaQuery.sizeOf(context).width < 700) {
      return Dialog.fullscreen(
        key: const Key('pos_buyer_information_dialog'),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.redInvoiceEditTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Expanded(child: content),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      key: const Key('pos_buyer_information_dialog'),
      title: Text(context.l10n.redInvoiceEditTitle),
      content: content,
      actions: actions,
    );
  }
}

String buyerSaveError(
  BuildContext context,
  BuyerInformationController controller,
  Object failure,
) {
  final copy = BuyerNumberCopy(Localizations.localeOf(context).languageCode);
  if (failure is PostgrestException &&
      failure.message == 'POS_BUYER_NUMBER_INVALID') {
    try {
      final detail = jsonDecode(failure.details.toString()) as Map;
      controller.serverNumberError = copy.error(
        BuyerNumberIssue(
          detail['code'].toString(),
          actual: detail['actual'] as int?,
          left: detail['left'] as int?,
          right: detail['right'] as int?,
        ),
      );
      controller.validate();
    } catch (_) {
      controller.numberFocus.requestFocus();
    }
  }
  return failure is PostgrestException && failure.message == 'POS_BUYER_CHANGED'
      ? copy.pick(
          '다른 직원이 수정했습니다. 최신 정보를 다시 조회해 주세요.',
          'Nhân viên khác đã sửa. Hãy tải lại thông tin mới.',
          'Another employee edited this record. Reload the latest information.',
        )
      : copy.pick(
          '저장하지 못했습니다. 입력한 내용은 유지됩니다.',
          'Không lưu được. Nội dung đã nhập được giữ lại.',
          'Save failed. Your entries have been retained.',
        );
}
