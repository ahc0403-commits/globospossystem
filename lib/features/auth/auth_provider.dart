import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, User;
import '../../main.dart';
import 'auth_state.dart';

class AuthNotifier extends StateNotifier<PosAuthState> {
  AuthNotifier() : super(const PosAuthState()) {
    _init();
  }

  StreamSubscription<dynamic>? _authSub;

  void _init() {
    final session = supabase.auth.currentSession;
    if (session != null) {
      _fetchUserProfile(session.user);
    }

    _authSub = supabase.auth.onAuthStateChange.listen((data) async {
      final event = data.event;
      final session = data.session;
      if (event == AuthChangeEvent.signedIn && session != null) {
        await _fetchUserProfile(session.user);
      } else if (event == AuthChangeEvent.signedOut) {
        state = const PosAuthState();
      }
    });
  }

  Future<void> _fetchUserProfile(User user) async {
    try {
      final data = await supabase
          .from('users')
          .select('role, restaurant_id, is_active, extra_permissions')
          .eq('auth_id', user.id)
          .single();

      final isActive = data['is_active'] as bool? ?? true;
      if (!isActive) {
        await supabase.auth.signOut();
        state = const PosAuthState(errorMessage: '비활성화된 계정입니다. 관리자에게 문의하세요.');
        return;
      }

      final extraRaw = data['extra_permissions'];
      final extraPermissions = extraRaw is List
          ? extraRaw.map((e) => e.toString()).toList()
          : const <String>[];

      state = state.copyWith(
        isLoading: false,
        user: user,
        role: data['role'] as String?,
        restaurantId: data['restaurant_id'] as String?,
        extraPermissions: extraPermissions,
        clearError: true,
      );
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        user: user,
        errorMessage: '사용자 정보를 불러올 수 없습니다.',
      );
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (response.user != null) {
        await _fetchUserProfile(response.user!);
      }
    } on AuthException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '로그인 중 오류가 발생했습니다.',
      );
    }
  }

  Future<void> logout() async {
    await supabase.auth.signOut();
    state = const PosAuthState();
  }

  Future<void> refreshProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      state = const PosAuthState();
      return;
    }
    await _fetchUserProfile(user);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, PosAuthState>(
  (ref) => AuthNotifier(),
);
