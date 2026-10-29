// Isolated browser fixture entry point. Never shipped by the production target.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'pos_layout_fixtures.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  final query = Uri.base.queryParameters;
  runApp(
    reportsLayoutFixture(
      language: ['ko', 'en', 'vi'].contains(query['language'])
          ? query['language']!
          : 'vi',
      scale: double.tryParse(query['scale'] ?? '') ?? 1,
      role: query['role'] == 'super_admin' ? 'super_admin' : 'store_admin',
      report: LayoutSampleReport(scene: query['scene'] ?? 'populated'),
    ),
  );
}
