import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF5A623)),
        useMaterial3: true,
      ),
      home: const Scaffold(
        backgroundColor: Color(0xFF111210),
        body: Center(
          child: Text(
            'GLOBOS POS',
            style: TextStyle(
              color: Color(0xFFF5A623),
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
