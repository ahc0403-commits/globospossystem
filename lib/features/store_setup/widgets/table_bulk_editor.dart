import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_models.dart';

class TableBulkEditor extends StatefulWidget {
  const TableBulkEditor({
    super.key,
    required this.tables,
    required this.onAdd,
    required this.onRemove,
    required this.onReassign,
  });

  final List<StoreSetupTableDraft> tables;
  final ValueChanged<List<StoreSetupTableDraft>> onAdd;
  final ValueChanged<int> onRemove;
  final void Function(Set<int> indexes, String floor) onReassign;

  @override
  State<TableBulkEditor> createState() => _TableBulkEditorState();
}

class _TableBulkEditorState extends State<TableBulkEditor> {
  final _paste = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _prefix = TextEditingController();
  final Set<int> _selected = {};
  String _floor = '1F';
  int _seats = 4;

  @override
  void dispose() {
    _paste.dispose();
    _start.dispose();
    _end.dispose();
    _prefix.dispose();
    super.dispose();
  }

  void _add() {
    try {
      final pasted = parsePastedTableNumbers(
        value: _paste.text,
        floorLabel: _floor,
        seatCount: _seats,
      );
      final start = int.tryParse(_start.text.trim());
      final end = int.tryParse(_end.text.trim());
      final generated = start == null || end == null
          ? const <StoreSetupTableDraft>[]
          : _prefix.text.trim().isEmpty
          ? generateNumericTableRange(
              start: start,
              end: end,
              floorLabel: _floor,
              seatCount: _seats,
            )
          : generatePrefixedTableRange(
              prefix: _prefix.text,
              start: start,
              end: end,
              floorLabel: _floor,
              seatCount: _seats,
            );
      if (pasted.isNotEmpty || generated.isNotEmpty) {
        widget.onAdd([...pasted, ...generated]);
        _paste.clear();
        _start.clear();
        _end.clear();
      }
    } on FormatException {
      // Server validation remains authoritative; invalid range input simply
      // stays in the editor for correction.
    }
  }

  @override
  Widget build(BuildContext context) {
    final duplicateNumbers = duplicateTableNumbers(widget.tables);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 260,
              child: TextField(
                key: const Key('store_setup_table_paste'),
                controller: _paste,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupPasteTables,
                ),
              ),
            ),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _start,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupRangeStart,
                ),
              ),
            ),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _end,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupRangeEnd,
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _prefix,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupPrefix,
                ),
              ),
            ),
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: _floor,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupFloor,
                ),
                items: [
                  DropdownMenuItem(value: '1F', child: Text('1F')),
                  DropdownMenuItem(value: '2F', child: Text('2F')),
                  DropdownMenuItem(value: '3F', child: Text('3F')),
                ],
                onChanged: (value) => setState(() => _floor = value ?? '1F'),
              ),
            ),
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<int>(
                initialValue: _seats,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupSeatCount,
                ),
                items: [
                  for (final seats in [1, 2, 4, 6, 8, 10])
                    DropdownMenuItem(value: seats, child: Text('$seats')),
                ],
                onChanged: (value) => setState(() => _seats = value ?? 4),
              ),
            ),
            FilledButton.icon(
              key: const Key('store_setup_add_tables'),
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.storeSetupAddTables),
            ),
          ],
        ),
        if (duplicateNumbers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              context.l10n.storeSetupDuplicateTables(
                duplicateNumbers.join(', '),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 18),
        Text(
          context.l10n.storeSetupExistingTables,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < widget.tables.length; index++)
          Card(
            child: CheckboxListTile(
              key: Key('store_setup_table_$index'),
              value: _selected.contains(index),
              onChanged: widget.tables[index].isProtected
                  ? null
                  : (value) => setState(() {
                      value == true
                          ? _selected.add(index)
                          : _selected.remove(index);
                    }),
              title: Text(
                '${widget.tables[index].tableNumber} · '
                '${widget.tables[index].floorLabel} · '
                '${widget.tables[index].seatCount}',
              ),
              subtitle: widget.tables[index].isProtected
                  ? Text(context.l10n.storeSetupProtectedTable)
                  : null,
              secondary: widget.tables[index].existingId == null
                  ? IconButton(
                      onPressed: () => widget.onRemove(index),
                      icon: const Icon(Icons.delete_outline),
                    )
                  : null,
            ),
          ),
        if (_selected.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final floor in StoreOpeningTemplate.floors)
                OutlinedButton(
                  onPressed: () {
                    widget.onReassign({..._selected}, floor);
                    setState(_selected.clear);
                  },
                  child: Text('${context.l10n.storeSetupFloor} $floor'),
                ),
            ],
          ),
      ],
    );
  }
}
