import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../core/utils/role_routes.dart';
import '../../main.dart';
import '../../widgets/language_switcher.dart';
import 'auth_provider.dart';
import 'auth_state.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    // 로그인 성공 시 router redirect가 처리
    ref.listen(authProvider, (prev, next) {
      final role = next.role;
      if (next.user != null && role != null && !next.privacyConsentRequired) {
        context.go(homeRouteForRole(role));
      }
    });

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: ToastShell(
        contentPadding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 980) {
              return Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(width: 420, child: _buildBrandPanel()),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 72,
                              ),
                              child: _buildLoginForm(context, authState),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: _buildLoginForm(context, authState),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBrandPanel() {
    final l10n = context.l10n;

    return Container(
      decoration: const BoxDecoration(
        color: PosColors.surface,
        border: Border(right: BorderSide(color: PosColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: PosColors.accent,
                  borderRadius: AppRadius.sm,
                ),
                child: Text(
                  'G',
                  style: GoogleFonts.notoSansKr(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GLOBOS Operations',
                      style: GoogleFonts.notoSansKr(
                        fontSize: 17,
                        color: PosColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      l10n.loginBrandBadge,
                      style: AppTextStyles.operationalCaption(
                        color: PosColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: PosColors.panelMuted,
              border: Border.all(color: PosColors.border),
              borderRadius: ToastRadiusTokens.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.loginBrandTitle,
                  style: GoogleFonts.notoSansKr(
                    fontSize: 22,
                    color: PosColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.loginBrandDescription,
                  style: GoogleFonts.notoSansKr(
                    fontSize: 13,
                    color: PosColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(height: 1, color: PosColors.border),
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.loginShiftFocus,
            style: GoogleFonts.notoSansKr(
              fontSize: 12,
              color: PosColors.textMuted,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildBrandMetric(
            l10n.loginMetricDiningRoomTitle,
            l10n.loginMetricDiningRoomSubtitle,
            Icons.table_bar_outlined,
          ),
          _buildBrandMetric(
            l10n.loginMetricKitchenTitle,
            l10n.loginMetricKitchenSubtitle,
            Icons.soup_kitchen_outlined,
          ),
          _buildBrandMetric(
            l10n.loginMetricCheckoutTitle,
            l10n.loginMetricCheckoutSubtitle,
            Icons.payments_outlined,
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: const BoxDecoration(
              color: PosColors.panelMuted,
              border: Border(
                top: BorderSide(color: PosColors.border),
                bottom: BorderSide(color: PosColors.border),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      ToastStatusBadge(
                        label: l10n.loginFastOrdering,
                        color: PosColors.info,
                      ),
                      ToastStatusBadge(
                        label: l10n.loginPaymentReady,
                        color: PosColors.accent,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ToastStatusBadge(
                  label: l10n.loginTabletReady,
                  color: PosColors.success,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginForm(BuildContext context, PosAuthState authState) {
    final l10n = context.l10n;

    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ToastWorkSurface(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Align(
                alignment: Alignment.centerRight,
                child: LanguageSwitcher(compact: true),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                l10n.loginStartShift,
                style: GoogleFonts.notoSansKr(
                  fontSize: 24,
                  color: PosColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.loginStartShiftDescription,
                style: GoogleFonts.notoSansKr(
                  fontSize: 14,
                  color: PosColors.textMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                key: const Key('login_email_field'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: PosColors.text),
                decoration: InputDecoration(
                  labelText: l10n.email,
                  labelStyle: const TextStyle(color: PosColors.textMuted),
                  prefixIcon: const Icon(
                    Icons.alternate_email,
                    color: PosColors.textMuted,
                  ),
                  filled: true,
                  fillColor: PosColors.panelMuted,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: ToastRadiusTokens.xs,
                    borderSide: const BorderSide(color: PosColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: ToastRadiusTokens.xs,
                    borderSide: const BorderSide(
                      color: PosColors.accent,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                key: const Key('login_password_field'),
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: PosColors.text),
                decoration: InputDecoration(
                  labelText: l10n.password,
                  labelStyle: const TextStyle(color: PosColors.textMuted),
                  prefixIcon: const Icon(
                    Icons.lock_outline,
                    color: PosColors.textMuted,
                  ),
                  filled: true,
                  fillColor: PosColors.panelMuted,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: ToastRadiusTokens.xs,
                    borderSide: const BorderSide(color: PosColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: ToastRadiusTokens.xs,
                    borderSide: const BorderSide(
                      color: PosColors.accent,
                      width: 1.5,
                    ),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: PosColors.textMuted,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              if (authState.errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                ToastStatusBadge(
                  label: l10n.loginErrorTitle,
                  color: PosColors.danger,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _localizedAuthError(context, authState.errorMessage!),
                  key: const Key('auth_error_text'),
                  style: GoogleFonts.notoSansKr(
                    fontSize: 13,
                    color: PosColors.danger,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  key: const Key('login_submit_button'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: PosColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.sm),
                  ),
                  onPressed: authState.isLoading
                      ? null
                      : () => ref
                            .read(authProvider.notifier)
                            .login(
                              _emailController.text,
                              _passwordController.text,
                            ),
                  child: authState.isLoading
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        )
                      : Text(
                          l10n.loginOpenTerminal,
                          style: GoogleFonts.notoSansKr(
                            fontSize: 15,
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrandMetric(String title, String subtitle, IconData icon) {
    return PosListRow(
      minHeight: 58,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(icon, color: PosColors.textMuted, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: GoogleFonts.notoSansKr(
                    fontSize: 14,
                    color: PosColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.notoSansKr(
                    fontSize: 12,
                    color: PosColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: PosColors.textMuted, size: 18),
        ],
      ),
    );
  }

  String _localizedAuthError(BuildContext context, String rawMessage) {
    final l10n = context.l10n;
    return switch (rawMessage) {
      'Account is deactivated. Contact your administrator.' =>
        l10n.loginAccountDeactivated,
      authErrorAccountDeactivated => l10n.loginAccountDeactivated,
      'Login succeeded, but this account is not linked to a POS user profile.' =>
        l10n.loginProfileMissing,
      authErrorProfileMissing => l10n.loginProfileMissing,
      'Login succeeded, but this account does not have permission to load its POS profile.' =>
        l10n.loginProfilePermissionDenied,
      authErrorProfilePermissionDenied => l10n.loginProfilePermissionDenied,
      'Login succeeded, but your POS account profile could not be loaded.' =>
        l10n.loginProfileLoadFailed,
      authErrorProfileLoadFailed => l10n.loginProfileLoadFailed,
      'An error occurred during login.' => l10n.loginGenericError,
      authErrorGenericLogin => l10n.loginGenericError,
      _
          when rawMessage.startsWith(
            'Login succeeded, but the POS profile lookup failed:',
          ) =>
        '${l10n.loginProfileLookupFailed} ${rawMessage.split(':').skip(1).join(':').trim()}',
      _ when rawMessage.startsWith(authErrorProfileLookupFailedPrefix) =>
        '${l10n.loginProfileLookupFailed} ${rawMessage.substring(authErrorProfileLookupFailedPrefix.length).trim()}',
      _ => rawMessage,
    };
  }
}
