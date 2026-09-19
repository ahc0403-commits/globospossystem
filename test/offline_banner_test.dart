import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/widgets/offline_banner.dart';

Widget bannerHarness(
  ServiceConnectivityState state, {
  ConnectivityService? service,
}) {
  return ProviderScope(
    overrides: [
      serviceConnectivityProvider.overrideWith((ref) => Stream.value(state)),
      if (service != null)
        connectivityServiceProvider.overrideWithValue(service),
    ],
    child: const MaterialApp(
      locale: Locale('ko'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: Column(children: [OfflineBanner()])),
    ),
  );
}

void main() {
  testWidgets('server delay is not described as an internet outage', (
    tester,
  ) async {
    await tester.pumpWidget(
      bannerHarness(
        ServiceConnectivityState(
          kind: ServiceConnectivityKind.serverDegraded,
          lastSuccessAt: DateTime(2026, 9, 19, 8, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('서버 응답 지연'), findsOneWidget);
    expect(find.textContaining('인터넷은 연결되어 있지만'), findsOneWidget);
    expect(find.textContaining('마지막 정상 연결'), findsOneWidget);
    expect(find.text('오프라인'), findsNothing);
  });

  testWidgets('confirmed transport loss is shown as offline', (tester) async {
    await tester.pumpWidget(
      bannerHarness(
        const ServiceConnectivityState(
          kind: ServiceConnectivityKind.networkUnavailable,
          consecutiveNetworkFailures: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오프라인'), findsOneWidget);
    expect(find.textContaining('인터넷 연결이 끊어졌습니다'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });

  testWidgets('auth failure asks for sign-in instead of blaming internet', (
    tester,
  ) async {
    await tester.pumpWidget(
      bannerHarness(
        const ServiceConnectivityState(
          kind: ServiceConnectivityKind.authRequired,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('다시 로그인 필요'), findsOneWidget);
    expect(find.textContaining('로그인 세션이 만료'), findsOneWidget);
    expect(find.text('오프라인'), findsNothing);
  });

  testWidgets('retry button runs one explicit health refresh', (tester) async {
    var probes = 0;
    final service = ConnectivityService(
      probe: () async {
        probes += 1;
        return const ConnectivityProbeResult.reachable(statusCode: 200);
      },
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      bannerHarness(
        const ServiceConnectivityState(
          kind: ServiceConnectivityKind.serverDegraded,
        ),
        service: service,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(probes, 1);
  });
}
