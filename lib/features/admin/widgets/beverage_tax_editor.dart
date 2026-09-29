import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/payments/beverage_tax.dart';

class BeverageTaxEditor extends StatefulWidget {
  const BeverageTaxEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.vatCategory,
  });

  final BeverageTax value;
  final ValueChanged<BeverageTax> onChanged;
  final String? vatCategory;

  @override
  State<BeverageTaxEditor> createState() => _BeverageTaxEditorState();
}

class _BeverageTaxEditorState extends State<BeverageTaxEditor> {
  late final _sugar = TextEditingController(
    text: widget.value.sugarGrams?.toString() ?? '',
  );
  late final _basis = TextEditingController(text: widget.value.basisNote);

  @override
  void dispose() {
    _sugar.dispose();
    _basis.dispose();
    super.dispose();
  }

  void _update({String? sugarClass}) {
    final raw = _sugar.text.trim().replaceAll(',', '.');
    final grams = raw.isEmpty ? null : double.tryParse(raw) ?? double.nan;
    widget.onChanged(
      BeverageTax(
        sugarClass:
            sugarClass ??
            (grams != null && grams.isFinite
                ? (grams > 5 ? 'gt_5' : 'lte_5')
                : widget.value.sugarClass),
        sugarGrams: grams,
        basisNote: _basis.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('menu_beverage_tax_class_${widget.value.sugarClass}'),
          initialValue: widget.value.sugarClass,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.menuBeverageTax),
          items: [
            DropdownMenuItem(
              value: 'not_applicable',
              child: Text(l10n.menuTaxNotApplicable),
            ),
            DropdownMenuItem(
              value: 'lte_5',
              child: Text(l10n.menuSugarAtMostFive),
            ),
            DropdownMenuItem(
              value: 'gt_5',
              child: Text(l10n.menuSugarAboveFive),
            ),
          ],
          onChanged: widget.vatCategory == 'alcohol'
              ? null
              : (value) {
                  if (value == null) return;
                  if (value == 'not_applicable') {
                    _sugar.clear();
                    _basis.clear();
                  }
                  _update(sugarClass: value);
                },
        ),
        if (widget.value.isApplicable) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('menu_sugar_grams'),
            controller: _sugar,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: l10n.menuSugarGrams),
            onChanged: (_) => _update(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('menu_tax_basis'),
            controller: _basis,
            maxLength: 500,
            decoration: InputDecoration(labelText: l10n.menuTaxBasis),
            onChanged: (_) => _update(),
          ),
          Text(l10n.menuSugarTaxHelp),
        ],
        const SizedBox(height: 8),
        Text(
          'VAT ${widget.value.vatRate(vatCategory: widget.vatCategory).toInt()}%',
        ),
      ],
    );
  }
}
