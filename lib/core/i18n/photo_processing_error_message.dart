import '../../l10n/app_localizations.dart';

String photoProcessingErrorMessage(AppLocalizations l10n, String code) =>
    switch (code) {
      'PHOTO_INPUT_TOO_LARGE' ||
      'PHOTO_OUTPUT_TOO_LARGE' => l10n.photoFileTooLarge,
      'PHOTO_PROCESSOR_BUSY' => l10n.photoProcessorBusy,
      _ => l10n.photoInvalid,
    };
