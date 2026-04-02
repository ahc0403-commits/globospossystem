Implement Auth (login) feature for the GLOBOS POS Flutter app. Follow the exact specifications below.

## Project Context
- Flutter Native (macOS/Android/iOS)
- Supabase Auth already configured via supabase_flutter
- State management: Riverpod (flutter_riverpod + riverpod_annotation)
- Routing: go_router
- Fonts: google_fonts (BebasNeue for headings, NotoSansKR for body)
- AppColors already defined in lib/main.dart:
  - surface0: Color(0xFF111210)
  - surface1: Color(0xFF1C1D1A)
  - surface2: Color(0xFF252621)
  - textPrimary: Color(0xFFF0EDE6)
  - textSecondary: Color(0xFF9E9B92)
  - amber500: Color(0xFFF5A623)
  - statusAvailable: Color(0xFF4CAF7D)
  - statusOccupied: Color(0xFFE8935A)
  - statusCancelled: Color(0xFFC0392B)
- Supabase global client already declared in main.dart: `final supabase = Supabase.instance.client;`

## Files to Create

### 1. lib/features/auth/auth_state.dart
Define a plain Dart class (not freezed) called AuthState with these fields:
- bool isLoading
- User? user  (from supabase_flutter)
- String? role
- String? restaurantId
- String? errorMessage

Include a copyWith method and a default constructor with all fields optional (default: isLoading false, rest null).

---

### 2. lib/features/auth/auth_provider.dart
Create a Riverpod StateNotifier called AuthNotifier with StateNotifierProvider<AuthNotifier, AuthState>.

Responsibilities:
- On init, call `supabase.auth.onAuthStateChange` stream to detect session changes
- If session exists on startup, fetch user role and restaurantId from the `users` table:
  `supabase.from('users').select('role, restaurant_id').eq('auth_id', userId).single()`
- Login method: `Future<void> login(String email, String password)`
  - Set isLoading = true
  - Call `supabase.auth.signInWithPassword(email: email, password: password)`
  - On success, fetch role + restaurantId from users table
  - On error, set errorMessage
  - Always set isLoading = false
- Logout method: `Future<void> logout()`
  - Call `supabase.auth.signOut()`
  - Reset state to default

Export a provider:
`final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier());`

---

### 3. lib/core/router/app_router.dart
Create a GoRouter instance using authProvider for redirect logic.

Routes:
- `/login` → LoginScreen
- `/waiter` → placeholder Scaffold with dark background and centered text "Waiter Screen"
- `/kitchen` → placeholder Scaffold with dark background and centered text "Kitchen Screen"
- `/cashier` → placeholder Scaffold with dark background and centered text "Cashier Screen"
- `/admin` → placeholder Scaffold with dark background and centered text "Admin Screen"

Redirect logic:
- If user is null → redirect to /login (except if already on /login)
- If user is logged in and on /login → redirect based on role:
  - 'waiter' → /waiter
  - 'kitchen' → /kitchen
  - 'cashier' → /cashier
  - 'admin' or 'super_admin' → /admin
  - default → /waiter
- Use ref.watch(authProvider) for state

Export:
`final appRouter = GoRouter(...)`

---

### 4. lib/features/auth/login_screen.dart
A StatefulWidget login screen.

Layout:
- Background: AppColors.surface0 (#111210)
- Centered Column, max width 400px using ConstrainedBox
- Logo section at top:
  - "GLOBOS" in BebasNeue, 56px, AppColors.amber500, letterSpacing 6
  - "POS SYSTEM" in NotoSansKR, 13px, AppColors.textSecondary, letterSpacing 4
  - SizedBox height 48
- Email TextField:
  - Label: "Email"
  - keyboardType: emailAddress
  - Style: textPrimary color
  - Filled with surface1 background
  - Focused border: amber500, radius 12
  - Enabled border: surface2, radius 12
- SizedBox height 16
- Password TextField:
  - Label: "Password"
  - obscureText toggle with suffix icon (visibility/visibility_off)
  - Same styling as email field
- SizedBox height 8
- Error message Text (if errorMessage != null):
  - Color: statusCancelled
  - FontSize: 13
  - NotoSansKR
- SizedBox height 24
- Login button:
  - Full width ElevatedButton
  - Height: 56px
  - Background: amber500
  - Text color: #111210 (dark)
  - Text: "LOGIN" in BebasNeue, 20px, letterSpacing 3
  - BorderRadius: 12
  - When isLoading: show CircularProgressIndicator(color: surface0) instead of text, disable button
  - onPressed: call ref.read(authProvider.notifier).login(email, password)

Use ConsumerStatefulWidget to access authProvider.

---

### 5. Modify lib/main.dart
- Add import for app_router.dart
- Change MaterialApp to MaterialApp.router
- Add `routerConfig: appRouter`
- Remove the _SplashScreen class and the home parameter
- Keep all AppColors, Supabase init, dotenv, ProviderScope

---

## Rules
- All Supabase calls must go through the provider/notifier layer. Never call supabase directly from a screen widget.
- No hardcoded strings for Supabase table names — use string literals in the provider only.
- Use const constructors wherever possible.
- After implementing all files, run `flutter analyze` and fix any errors before finishing.
- Do not use freezed for AuthState — plain Dart class only.
- After all files are created and analyze passes, run `flutter build macos` to confirm it compiles.
