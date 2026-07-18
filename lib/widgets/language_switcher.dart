import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/locale_controller.dart';
import '../core/i18n/locale_extensions.dart';
import '../core/i18n/locale_state.dart';
import '../core/ui/app_theme.dart';
import '../core/ui/pos_design_tokens.dart';

class LanguageSwitcher extends ConsumerWidget {
  const LanguageSwitcher({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeState = ref.watch(localeControllerProvider);
    final useCompact = compact || MediaQuery.sizeOf(context).width < 720;

    if (useCompact) {
      return _LanguageMenu(
        currentLanguage: localeState.language,
        onSelected: (language) =>
            ref.read(localeControllerProvider.notifier).setLocale(language),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: PosColors.panel,
        borderRadius: AppRadius.sm,
        border: Border.all(
          color: PosColors.border,
          width: PosMetrics.panelBorderWidth,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: AppLanguage.values
            .map(
              (language) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _LanguageChip(
                  language: language,
                  isSelected: localeState.language == language,
                  onTap: () => ref
                      .read(localeControllerProvider.notifier)
                      .setLocale(language),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _LanguageMenu extends StatelessWidget {
  const _LanguageMenu({
    required this.currentLanguage,
    required this.onSelected,
  });

  final AppLanguage currentLanguage;
  final ValueChanged<AppLanguage> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AppLanguage>(
      tooltip: context.l10n.language,
      onSelected: onSelected,
      color: PosColors.panel,
      itemBuilder: (context) => AppLanguage.values
          .map(
            (language) => PopupMenuItem<AppLanguage>(
              value: language,
              child: Text(_languageLabel(context, language)),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: PosColors.panel,
          borderRadius: AppRadius.sm,
          border: Border.all(
            color: PosColors.border,
            width: PosMetrics.panelBorderWidth,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 16, color: PosColors.textMuted),
            const SizedBox(width: 6),
            Text(
              currentLanguage.code.toUpperCase(),
              style: const TextStyle(
                color: PosColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.language,
    required this.isSelected,
    required this.onTap,
  });

  final AppLanguage language;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.sm,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: PosDensity.touchTargetMin,
          minHeight: PosDensity.touchTargetMin,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? PosColors.accent : Colors.transparent,
            borderRadius: AppRadius.sm,
          ),
          child: Text(
            language.code.toUpperCase(),
            style: TextStyle(
              color: isSelected ? Colors.white : PosColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

String _languageLabel(BuildContext context, AppLanguage language) {
  final l10n = context.l10n;
  return switch (language) {
    AppLanguage.english => l10n.languageEnglish,
    AppLanguage.korean => l10n.languageKorean,
    AppLanguage.vietnamese => l10n.languageVietnamese,
  };
}
