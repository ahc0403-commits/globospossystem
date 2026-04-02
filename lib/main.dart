import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/constants/app_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. .env 로드
  await dotenv.load(fileName: '.env');

  // 2. Supabase 초기화
  await Supabase.initialize(
    url: AppConstants.supabaseUrl,
    anonKey: AppConstants.supabaseAnonKey,
  );

  // 3. Riverpod + 앱 실행
  runApp(
    const ProviderScope(
      child: GlobosPosApp(),
    ),
  );
}

/// Supabase client 전역 접근용
final supabase = Supabase.instance.client;

class GlobosPosApp extends StatelessWidget {
  const GlobosPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GLOBOS POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.amber500),
        useMaterial3: true,
        textTheme: GoogleFonts.notoSansKrTextTheme(),
      ),
      home: const _SplashScreen(),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'GLOBOS',
              style: GoogleFonts.bebasNeue(
                fontSize: 64,
                color: AppColors.amber500,
                letterSpacing: 8,
              ),
            ),
            Text(
              'POS SYSTEM',
              style: GoogleFonts.notoSansKr(
                fontSize: 16,
                color: AppColors.textSecondary,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 앱 전역 색상 상수
class AppColors {
  static const surface0 = Color(0xFF111210);
  static const surface1 = Color(0xFF1C1D1A);
  static const surface2 = Color(0xFF252621);
  static const textPrimary = Color(0xFFF0EDE6);
  static const textSecondary = Color(0xFF9E9B92);
  static const amber500 = Color(0xFFF5A623);
  static const statusAvailable = Color(0xFF4CAF7D);
  static const statusOccupied = Color(0xFFE8935A);
  static const statusReady = Color(0xFFF5A623);
  static const statusCancelled = Color(0xFFC0392B);
}
