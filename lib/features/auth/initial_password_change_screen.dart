import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../widgets/language_switcher.dart';
import 'auth_provider.dart';

const initialPasswordFieldKey = Key('initial_password_new_field');
const initialPasswordConfirmFieldKey = Key('initial_password_confirm_field');
const initialPasswordSubmitButtonKey = Key('initial_password_submit_button');

bool isStrongInitialPassword(String value) {
  return value.length >= 12 &&
      RegExp('[a-z]').hasMatch(value) &&
      RegExp('[A-Z]').hasMatch(value) &&
      RegExp('[0-9]').hasMatch(value) &&
      RegExp(r'[^A-Za-z0-9]').hasMatch(value);
}

class InitialPasswordChangeScreen extends ConsumerStatefulWidget {
  const InitialPasswordChangeScreen({super.key});

  @override
  ConsumerState<InitialPasswordChangeScreen> createState() =>
      _InitialPasswordChangeScreenState();
}

class _InitialPasswordChangeScreenState
    extends ConsumerState<InitialPasswordChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    await ref
        .read(authProvider.notifier)
        .changeInitialPassword(_passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final auth = ref.watch(authProvider);
    final email = auth.user?.email ?? l10n.initialPasswordAccountUnknown;

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ToastWorkSurface(
                padding: EdgeInsets.zero,
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 16, 18),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: PosColors.accentMuted,
                                borderRadius: AppRadius.sm,
                              ),
                              child: const Icon(
                                Icons.lock_reset_outlined,
                                color: PosColors.accent,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.initialPasswordTitle,
                                    style: AppFonts.system(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900,
                                      color: PosColors.text,
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    l10n.initialPasswordSubtitle,
                                    style: AppFonts.system(
                                      fontSize: 13.5,
                                      height: 1.45,
                                      color: PosColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            const LanguageSwitcher(compact: true),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: PosColors.border),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.md,
                              ),
                              decoration: BoxDecoration(
                                color: PosColors.canvasAlt,
                                borderRadius: AppRadius.sm,
                                border: Border.all(color: PosColors.border),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.account_circle_outlined,
                                    color: PosColors.textMuted,
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          l10n.initialPasswordAccountLabel,
                                          style: AppFonts.system(
                                            fontSize: 12,
                                            color: PosColors.textMuted,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          email,
                                          style: AppFonts.system(
                                            fontSize: 15,
                                            color: PosColors.text,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),
                            TextFormField(
                              key: initialPasswordFieldKey,
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              enabled: !auth.isPasswordChangeSubmitting,
                              autofillHints: const [AutofillHints.newPassword],
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: l10n.initialPasswordNewLabel,
                                hintText: l10n.initialPasswordNewHint,
                                prefixIcon: const Icon(Icons.key_outlined),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword
                                      ? l10n.initialPasswordShow
                                      : l10n.initialPasswordHide,
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) =>
                                  isStrongInitialPassword(value ?? '')
                                  ? null
                                  : l10n.initialPasswordPolicyError,
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            TextFormField(
                              key: initialPasswordConfirmFieldKey,
                              controller: _confirmationController,
                              obscureText: _obscureConfirmation,
                              enabled: !auth.isPasswordChangeSubmitting,
                              autofillHints: const [AutofillHints.newPassword],
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                labelText: l10n.initialPasswordConfirmLabel,
                                prefixIcon: const Icon(
                                  Icons.verified_user_outlined,
                                ),
                                suffixIcon: IconButton(
                                  tooltip: _obscureConfirmation
                                      ? l10n.initialPasswordShow
                                      : l10n.initialPasswordHide,
                                  onPressed: () => setState(
                                    () => _obscureConfirmation =
                                        !_obscureConfirmation,
                                  ),
                                  icon: Icon(
                                    _obscureConfirmation
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) =>
                                  value == _passwordController.text
                                  ? null
                                  : l10n.initialPasswordMismatch,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _PasswordPolicyNotice(
                              text: l10n.initialPasswordPolicy,
                            ),
                            if (auth.errorMessage != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              Container(
                                key: const Key('initial_password_error'),
                                padding: const EdgeInsets.all(AppSpacing.md),
                                decoration: BoxDecoration(
                                  color: PosColors.danger.withValues(
                                    alpha: 0.08,
                                  ),
                                  borderRadius: AppRadius.sm,
                                  border: Border.all(
                                    color: PosColors.danger.withValues(
                                      alpha: 0.28,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  l10n.initialPasswordChangeFailed,
                                  style: AppFonts.system(
                                    fontSize: 13,
                                    color: PosColors.danger,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: AppSpacing.xl),
                            SizedBox(
                              height: 52,
                              child: FilledButton.icon(
                                key: initialPasswordSubmitButtonKey,
                                onPressed: auth.isPasswordChangeSubmitting
                                    ? null
                                    : _submit,
                                icon: auth.isPasswordChangeSubmitting
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.check_circle_outline),
                                label: Text(
                                  auth.isPasswordChangeSubmitting
                                      ? l10n.initialPasswordSaving
                                      : l10n.initialPasswordSubmit,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextButton.icon(
                              onPressed: auth.isPasswordChangeSubmitting
                                  ? null
                                  : () => ref
                                        .read(authProvider.notifier)
                                        .logout(),
                              icon: const Icon(Icons.logout, size: 18),
                              label: Text(l10n.initialPasswordLogout),
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
}

class _PasswordPolicyNotice extends StatelessWidget {
  const _PasswordPolicyNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.shield_outlined, size: 18, color: PosColors.info),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: AppFonts.system(
              fontSize: 12.5,
              height: 1.4,
              color: PosColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
