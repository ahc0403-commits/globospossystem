import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

String _message(BuildContext context, String ko, String en, String vi) =>
    switch (Localizations.localeOf(context).languageCode) {
      'ko' => ko,
      'vi' => vi,
      _ => en,
    };

class SessionRecoveryScreen extends ConsumerWidget {
  const SessionRecoveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (auth.isLoading) const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _message(
                  context,
                  '로그인을 복원하고 있습니다',
                  'Restoring your session',
                  'Đang khôi phục phiên đăng nhập',
                ),
              ),
              if (!auth.isLoading) ...[
                const SizedBox(height: 12),
                Text(
                  _message(
                    context,
                    '연결과 계정 정보를 다시 확인해 주세요.',
                    'Check the connection and retry your account.',
                    'Kiểm tra kết nối và thử lại tài khoản.',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () =>
                      ref.read(authProvider.notifier).refreshProfile(),
                  child: Text(_message(context, '다시 시도', 'Retry', 'Thử lại')),
                ),
              ],
              TextButton(
                onPressed: () => ref.read(authProvider.notifier).logout(),
                child: Text(_message(context, '로그아웃', 'Sign out', 'Đăng xuất')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionRecoveryBanner extends ConsumerWidget {
  const SessionRecoveryBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    if (!auth.isRecoveringSession || auth.user == null) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _message(
                      context,
                      '연결 복구 중 · 로그인 유지됨',
                      'Reconnecting · still signed in',
                      'Đang kết nối lại · vẫn đăng nhập',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(authProvider.notifier).refreshProfile(),
                  child: Text(_message(context, '재시도', 'Retry', 'Thử lại')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
