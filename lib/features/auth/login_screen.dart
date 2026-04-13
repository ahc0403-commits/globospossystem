import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
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

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: AppColors.textSecondary),
      filled: true,
      fillColor: AppColors.surface1,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.surface2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.amber500, width: 2),
      ),
    );
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 900) {
            return Row(
              children: [
                Expanded(
                  child: Container(
                    color: AppColors.surface1,
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'GLOBOS',
                          style: GoogleFonts.bebasNeue(
                            fontSize: 80,
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
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Powered by GLOBOSVN',
                          style: GoogleFonts.notoSansKr(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(child: Center(child: _buildLoginForm(authState))),
              ],
            );
          }

          return Center(child: _buildLoginForm(authState));
        },
      ),
    );
  }

  Widget _buildLoginForm(PosAuthState authState) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'GLOBOS',
              style: GoogleFonts.bebasNeue(
                fontSize: 56,
                color: AppColors.amber500,
                letterSpacing: 6,
              ),
            ),
            Text(
              'POS SYSTEM',
              style: GoogleFonts.notoSansKr(
                fontSize: 13,
                color: AppColors.textSecondary,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 48),
            TextField(
              key: const Key('login_email_field'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: _fieldDecoration('Email'),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('login_password_field'),
              controller: _passwordController,
              obscureText: _obscurePassword,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: _fieldDecoration('Password').copyWith(
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (authState.errorMessage != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  authState.errorMessage!,
                  key: const Key('auth_error_text'),
                  style: GoogleFonts.notoSansKr(
                    fontSize: 13,
                    color: AppColors.statusCancelled,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
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
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  disabledBackgroundColor: AppColors.amber500.withValues(
                    alpha: 0.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
      case 'admin':
        return '/admin';
      case 'super_admin':
        return '/super-admin';
      default:
        return '/waiter';
    }
  }
}
