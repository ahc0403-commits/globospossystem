import 'package:supabase_flutter/supabase_flutter.dart';

class PosAuthState {
  final bool isLoading;
  final User? user;
  final String? role;
  final String? storeId;
  final List<String> extraPermissions;
  final String? errorMessage;

  const PosAuthState({
    this.isLoading = false,
    this.user,
    this.role,
    this.storeId,
    this.extraPermissions = const [],
    this.errorMessage,
  });

  PosAuthState copyWith({
    bool? isLoading,
    User? user,
    String? role,
    String? storeId,
    List<String>? extraPermissions,
    String? errorMessage,
    bool clearError = false,
    bool clearUser = false,
  }) {
    return PosAuthState(
      isLoading: isLoading ?? this.isLoading,
      user: clearUser ? null : (user ?? this.user),
      role: clearUser ? null : (role ?? this.role),
      storeId: clearUser ? null : (storeId ?? this.storeId),
      extraPermissions: clearUser
          ? const []
          : (extraPermissions ?? this.extraPermissions),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
