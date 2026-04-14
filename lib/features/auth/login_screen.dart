import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/ui/app_primitives.dart';
import '../../main.dart';
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
      if (next.user != null && role != null) {
        context.go(_roleRoute(role));
      }
    });

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: AppShell(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 980) {
              return Row(
                children: [
                  Expanded(child: _buildBrandPanel()),
                  const SizedBox(width: AppSpacing.xl),
                  Expanded(child: Center(child: _buildLoginForm(authState))),
                ],
              );
            }

            return Center(child: _buildLoginForm(authState));
          },
        ),
      ),
    );
  }

  Widget _buildBrandPanel() {
    return AppPanel(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      backgroundColor: AppColors.surface1,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.amber500.withValues(alpha: 0.12),
              borderRadius: AppRadius.pill,
              border: Border.all(
                color: AppColors.amber500.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              'OPERATIONAL CONSOLE',
              style: AppTextStyles.operationalCaption(
                color: AppColors.amber500,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'GLOBOS',
            style: GoogleFonts.bebasNeue(
              fontSize: 92,
              color: AppColors.amber500,
              letterSpacing: 8,
            ),
          ),
          Text(
            'POS SYSTEM',
            style: GoogleFonts.notoSansKr(
              fontSize: 20,
              color: AppColors.textPrimary,
              letterSpacing: 4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Cashier, kitchen, attendance, and admin workflows in one operational surface.',
            style: GoogleFonts.notoSansKr(
              fontSize: 15,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: const [
              AppStatusBadge(label: 'FAST SCAN', color: AppColors.statusInfo),
              AppStatusBadge(
                label: 'HIGH CONTRAST',
                color: AppColors.statusAvailable,
              ),
              AppStatusBadge(
                label: 'TABLET READY',
                color: AppColors.statusReady,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoginForm(PosAuthState authState) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: AppPanel(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppSectionHeader(
                title: 'LOGIN',
                subtitle:
                    'Sign in to continue to your role-specific workspace.',
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                key: const Key('login_email_field'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                key: const Key('login_password_field'),
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              if (authState.errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                const AppStatusBadge(
                  label: 'AUTH ERROR',
                  color: AppColors.statusCancelled,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  authState.errorMessage!,
                  key: const Key('auth_error_text'),
                  style: GoogleFonts.notoSansKr(
                    fontSize: 13,
                    color: AppColors.statusCancelled,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  key: const Key('login_submit_button'),
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
                          color: AppColors.surface0,
                          strokeWidth: 2,
                        )
                      : Text(
                          'LOGIN',
                          style: GoogleFonts.bebasNeue(
                            fontSize: 20,
                            color: AppColors.surface0,
                            letterSpacing: 3,
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

  String _roleRoute(String role) {
    switch (role) {
      case 'waiter':
        return '/waiter';
      case 'kitchen':
        return '/kitchen';
      case 'cashier':
        return '/cashier';
      case 'brand_admin':
      case 'store_admin':
      case 'admin':
        return '/admin';
      case 'photo_objet_master':
      case 'photo_objet_store_admin':
        return '/photo-ops';
      case 'super_admin':
        return '/super-admin';
      default:
        return '/waiter';
    }
  }
}
