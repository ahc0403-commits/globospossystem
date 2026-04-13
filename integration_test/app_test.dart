import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:globos_pos_system/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots smoke test', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('GLOBOS POS'), findsNothing);
    expect(find.byType(app.GlobosPosApp), findsOneWidget);
  });
}
