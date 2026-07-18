import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../core/i18n/locale_extensions.dart';
import '../core/ui/pos_design_tokens.dart';

Future<String?> showPinDialog(BuildContext context, {String? title}) async {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinDialog(title: title ?? context.l10n.pinEnterTitle),
  );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.title});

  final String title;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  String _pin = '';

  void _append(String digit) {
    if (_pin.length >= 4) return;
    setState(() => _pin += digit);
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Dialog(
      backgroundColor: PosColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              style: AppFonts.system(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 14),
            Semantics(
              liveRegion: true,
              label: '${_pin.length} / 4',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  final filled = index < _pin.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? PosColors.accent : Colors.transparent,
                      border: Border.all(color: PosColors.textSecondary),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 16),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['', '0', '<'],
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: row.map((key) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: SizedBox(
                          height: PosDensity.touchTargetMin,
                          child: key.isEmpty
                              ? const SizedBox.shrink()
                              : OutlinedButton(
                                  onPressed: () {
                                    if (key == '<') {
                                      _backspace();
                                    } else {
                                      _append(key);
                                    }
                                  },
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                      color: PosColors.mutedSurface,
                                    ),
                                  ),
                                  child: Text(
                                    key == '<' ? '⌫' : key,
                                    style: AppFonts.system(
                                      color: PosColors.textPrimary,
                                      fontSize: 24,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _pin.length == 4
                        ? () => Navigator.of(context).pop(_pin)
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: PosColors.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l10n.confirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
