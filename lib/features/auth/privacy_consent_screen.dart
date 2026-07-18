import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../core/utils/role_routes.dart';
import '../../widgets/language_switcher.dart';
import 'auth_provider.dart';

const privacyConsentAcceptButtonKey = Key('privacy_consent_accept_button');

class PrivacyConsentScreen extends ConsumerStatefulWidget {
  const PrivacyConsentScreen({super.key});

  @override
  ConsumerState<PrivacyConsentScreen> createState() =>
      _PrivacyConsentScreenState();
}

class _PrivacyConsentScreenState extends ConsumerState<PrivacyConsentScreen> {
  bool _accepted = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final authState = ref.watch(authProvider);

    ref.listen(authProvider, (prev, next) {
      final role = next.role;
      if (next.user != null &&
          role != null &&
          !next.privacyConsentRequired &&
          prev?.privacyConsentRequired == true) {
        context.go(homeRouteForRole(role));
      }
    });

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: ToastWorkSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: PosColors.accentMuted,
                                borderRadius: AppRadius.sm,
                              ),
                              child: const Icon(
                                Icons.privacy_tip_outlined,
                                color: PosColors.accent,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.privacyConsentTitle,
                                    style: AppFonts.system(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900,
                                      color: PosColors.text,
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    l10n.privacyConsentSubtitle,
                                    style: AppFonts.system(
                                      fontSize: 13.5,
                                      height: 1.45,
                                      color: PosColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            const LanguageSwitcher(compact: true),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: PosColors.border),
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _NoticeBox(text: l10n.privacyConsentLegalBasis),
                            const SizedBox(height: AppSpacing.lg),
                            _ConsentSection(
                              title: l10n.privacyConsentDataTitle,
                              children: [
                                l10n.privacyConsentDataAccount,
                                l10n.privacyConsentDataOperations,
                                l10n.privacyConsentDataDevice,
                              ],
                            ),
                            _ConsentSection(
                              title: l10n.privacyConsentPurposeTitle,
                              children: [
                                l10n.privacyConsentPurposeAuth,
                                l10n.privacyConsentPurposeOperations,
                                l10n.privacyConsentPurposeCompliance,
                                l10n.privacyConsentPurposeSupport,
                              ],
                            ),
                            _ConsentSection(
                              title: l10n.privacyConsentPartiesTitle,
                              children: [
                                l10n.privacyConsentPartiesControllers,
                                l10n.privacyConsentPartiesProcessors,
                                l10n.privacyConsentPartiesAuthorities,
                              ],
                            ),
                            _ConsentSection(
                              title: l10n.privacyConsentRightsTitle,
                              children: [
                                l10n.privacyConsentRightsConsent,
                                l10n.privacyConsentRightsAccess,
                                l10n.privacyConsentRightsWithdrawal,
                              ],
                            ),
                            _ConsentSection(
                              title: l10n.privacyConsentCrossBorderTitle,
                              children: [l10n.privacyConsentCrossBorderBody],
                            ),
                            _PledgeBox(text: l10n.privacyConsentPledgeBody),
                            if (authState.errorMessage != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                _localizedPrivacyConsentError(
                                  context,
                                  authState.errorMessage!,
                                ),
                                key: const Key('privacy_consent_error_text'),
                                style: AppFonts.system(
                                  fontSize: 13,
                                  color: PosColors.danger,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: PosColors.border),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            CheckboxListTile(
                              key: const Key('privacy_consent_checkbox'),
                              value: _accepted,
                              onChanged: authState.isPrivacyConsentSubmitting
                                  ? null
                                  : (value) => setState(
                                      () => _accepted = value ?? false,
                                    ),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                l10n.privacyConsentAgreeCheckbox,
                                style: AppFonts.system(
                                  fontSize: 13.5,
                                  color: PosColors.text,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.sm,
                              children: [
                                OutlinedButton.icon(
                                  onPressed:
                                      authState.isPrivacyConsentSubmitting
                                      ? null
                                      : () => ref
                                            .read(authProvider.notifier)
                                            .logout(),
                                  icon: const Icon(Icons.logout, size: 18),
                                  label: Text(l10n.privacyConsentDecline),
                                ),
                                FilledButton.icon(
                                  key: privacyConsentAcceptButtonKey,
                                  onPressed:
                                      !_accepted ||
                                          authState.isPrivacyConsentSubmitting
                                      ? null
                                      : () => ref
                                            .read(authProvider.notifier)
                                            .acceptPrivacyConsent(
                                              localeName:
                                                  Localizations.localeOf(
                                                    context,
                                                  ).toLanguageTag(),
                                            ),
                                  icon: authState.isPrivacyConsentSubmitting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.verified_user_outlined,
                                        ),
                                  label: Text(l10n.privacyConsentAccept),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _localizedPrivacyConsentError(BuildContext context, String message) {
    final l10n = context.l10n;
    return switch (message) {
      authErrorPrivacyConsentSetupMissing => l10n.privacyConsentSetupMissing,
      authErrorPrivacyConsentProfileMissing =>
        l10n.privacyConsentProfileMissing,
      authErrorPrivacyConsentPermissionDenied =>
        l10n.privacyConsentPermissionDenied,
      authErrorPrivacyConsentFailed => l10n.privacyConsentSubmitFailed,
      _ when message.startsWith(authErrorPrivacyConsentFailedPrefix) =>
        l10n.privacyConsentSubmitFailedWithDetail(
          message.substring(authErrorPrivacyConsentFailedPrefix.length).trim(),
        ),
      _ => message,
    };
  }
}

class _ConsentSection extends StatelessWidget {
  const _ConsentSection({required this.title, required this.children});

  final String title;
  final List<String> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: PosColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...children.map((item) => _BulletText(text: item)),
        ],
      ),
    );
  }
}

class _BulletText extends StatelessWidget {
  const _BulletText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Icon(Icons.circle, size: 6, color: PosColors.textMuted),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppFonts.system(
                fontSize: 13,
                height: 1.45,
                color: PosColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeBox extends StatelessWidget {
  const _NoticeBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: PosColors.infoMuted,
        border: Border.all(color: PosColors.info.withValues(alpha: 0.22)),
        borderRadius: ToastRadiusTokens.xs,
      ),
      child: Text(
        text,
        style: AppFonts.system(
          fontSize: 13,
          height: 1.5,
          color: PosColors.text,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PledgeBox extends StatelessWidget {
  const _PledgeBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        border: Border.all(color: PosColors.border),
        borderRadius: ToastRadiusTokens.xs,
      ),
      child: Text(
        text,
        style: AppFonts.system(
          fontSize: 13,
          height: 1.55,
          color: PosColors.text,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
