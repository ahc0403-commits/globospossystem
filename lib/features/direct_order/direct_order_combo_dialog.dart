import 'package:flutter/material.dart';
import 'direct_order_copy.dart';
import 'direct_order_models.dart';

class DirectOrderComboDialog extends StatefulWidget {
  const DirectOrderComboDialog({
    super.key,
    required this.item,
    required this.quantity,
    required this.languageCode,
    this.initial = const [],
  });
  final DirectOrderMenuItem item;
  final int quantity;
  final String languageCode;
  final List<String> initial;
  @override
  State<DirectOrderComboDialog> createState() => _DirectOrderComboDialogState();
}

class _DirectOrderComboDialogState extends State<DirectOrderComboDialog> {
  final counts = <String, int>{};
  int get selected => counts.values.fold(0, (a, b) => a + b);
  int get requiredCount => widget.item.comboDrinkChoiceCount * widget.quantity;
  @override
  void initState() {
    super.initState();
    final available = widget.item.comboDrinkOptions
        .map((o) => o.menuItemId)
        .toSet();
    for (final id in widget.initial.take(requiredCount)) {
      if (available.contains(id)) counts[id] = (counts[id] ?? 0) + 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(widget.languageCode);
    return AlertDialog(
      key: const Key('direct_combo_dialog'),
      title: Text(copy.comboDrinks),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.item.localizedName(widget.languageCode)} × ${widget.quantity}',
            ),
            Text(
              copy.comboDrinkCount(selected, requiredCount),
              key: const Key('direct_combo_progress'),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in widget.item.comboDrinkOptions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(option.localizedName(widget.languageCode)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key('direct_combo_minus_${option.menuItemId}'),
                            onPressed: (counts[option.menuItemId] ?? 0) == 0
                                ? null
                                : () => setState(() {
                                    counts[option.menuItemId] =
                                        counts[option.menuItemId]! - 1;
                                  }),
                            icon: const Icon(Icons.remove),
                          ),
                          Text('${counts[option.menuItemId] ?? 0}'),
                          IconButton(
                            key: Key('direct_combo_plus_${option.menuItemId}'),
                            onPressed: selected >= requiredCount
                                ? null
                                : () => setState(() {
                                    counts[option.menuItemId] =
                                        (counts[option.menuItemId] ?? 0) + 1;
                                  }),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(copy.close),
        ),
        FilledButton(
          key: const Key('direct_combo_confirm'),
          onPressed: selected != requiredCount
              ? null
              : () => Navigator.pop(context, [
                  for (final option in widget.item.comboDrinkOptions)
                    for (var n = 0; n < (counts[option.menuItemId] ?? 0); n++)
                      option.menuItemId,
                ]),
          child: Text(copy.save),
        ),
      ],
    );
  }
}
