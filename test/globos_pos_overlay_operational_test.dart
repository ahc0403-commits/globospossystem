import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/toast/toast.dart';
import 'package:globos_pos_system/features/cashier/discount_modal.dart';
import 'package:globos_pos_system/features/cashier/payment_proof_modal.dart';
import 'package:globos_pos_system/features/cashier/red_invoice_modal.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/widgets/pin_dialog.dart';

enum _OverlayKind { discount, paymentProof, redInvoice, pin, confirm }

class _ViewportLocale {
  const _ViewportLocale(this.size, this.locale);

  final Size size;
  final Locale locale;
}

const _viewportLocales = <_ViewportLocale>[
  _ViewportLocale(Size(390, 844), Locale('ko')),
  _ViewportLocale(Size(1024, 768), Locale('en')),
  _ViewportLocale(Size(1440, 900), Locale('vi')),
];

class _OverlayHost extends StatefulWidget {
  const _OverlayHost({super.key, required this.kind});

  final _OverlayKind kind;

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> {
  String? _result;

  Future<void> _open() async {
    final l10n = AppLocalizations.of(context)!;
    final result = switch (widget.kind) {
      _OverlayKind.discount => await showDialog<Object?>(
        context: context,
        builder: (_) => const DiscountModal(
          orderId: 'overlay-order',
          storeId: 'overlay-store',
          menuSubtotal: 100000,
          serviceChargeTotal: 5000,
        ),
      ),
      _OverlayKind.paymentProof => await showDialog<Object?>(
        context: context,
        builder: (_) => const PaymentProofModal(
          paymentId: 'overlay-payment',
          storeId: 'overlay-store',
          methodLabel: 'QR',
        ),
      ),
      _OverlayKind.redInvoice => await showDialog<Object?>(
        context: context,
        builder: (_) => const RedInvoiceModal(
          orderId: 'overlay-order',
          storeId: 'overlay-store',
        ),
      ),
      _OverlayKind.pin => await showPinDialog(context),
      _OverlayKind.confirm => await ToastConfirmDialog.show(
        context: context,
        title: l10n.confirm,
        description: l10n.cancel,
        confirmLabel: l10n.confirm,
        cancelLabel: l10n.cancel,
        icon: Icons.verified_outlined,
      ),
    };
    if (!mounted) return;
    setState(() => _result = '${widget.kind.name}:$result');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open_overlay'),
          onPressed: _open,
          child: const Text('Open'),
        ),
      ),
      bottomNavigationBar: _result == null
          ? null
          : Text(_result!, key: const Key('overlay_result')),
    );
  }
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required _OverlayKind kind,
  required _ViewportLocale fixture,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = fixture.size;
  await tester.pumpWidget(
    MaterialApp(
      key: ValueKey('${kind.name}-${fixture.locale.languageCode}'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      locale: fixture.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: _OverlayHost(
        key: ValueKey('${kind.name}-${fixture.size}'),
        kind: kind,
      ),
    ),
  );
  await tester.pump();
}

Finder _dialog() {
  final alertDialog = find.byType(AlertDialog);
  return alertDialog.evaluate().isNotEmpty ? alertDialog : find.byType(Dialog);
}

String _localizedTitle(_OverlayKind kind, AppLocalizations l10n) =>
    switch (kind) {
      _OverlayKind.discount => l10n.cashierDiscountTitle,
      _OverlayKind.paymentProof => l10n.paymentProofTitle,
      _OverlayKind.redInvoice => l10n.redInvoiceTitle,
      _OverlayKind.pin => l10n.pinEnterTitle,
      _OverlayKind.confirm => l10n.confirm,
    };

void _expectVisibleButtonsAreTouchSized(WidgetTester tester, Finder dialog) {
  final buttons = find
      .descendant(
        of: dialog,
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      )
      .hitTestable();
  expect(buttons, findsWidgets);
  for (final element in buttons.evaluate()) {
    final target = find.byElementPredicate((candidate) => candidate == element);
    final size = tester.getSize(target);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  }
}

Future<void> _exerciseOverlay(
  WidgetTester tester,
  _OverlayKind kind,
  AppLocalizations l10n,
) async {
  switch (kind) {
    case _OverlayKind.discount:
      final valueField = find.byType(TextField).first;
      await tester.enterText(valueField, '10000');
      await tester.pump();
      expect(tester.widget<TextField>(valueField).controller?.text, '10000');
      await tester.tap(find.text(l10n.cancel).last);
      break;
    case _OverlayKind.paymentProof:
      await tester.tap(find.text(l10n.paymentProofSkipForNow));
      break;
    case _OverlayKind.redInvoice:
      await tester.tap(find.text(l10n.redInvoiceIssueInvoice));
      await tester.pump();
      expect(find.text(l10n.redInvoiceEmailRequiredLabel), findsOneWidget);
      await tester.tap(find.text(l10n.back));
      await tester.pump();
      await tester.tap(find.text(l10n.no));
      break;
    case _OverlayKind.pin:
      for (final digit in const ['1', '2', '3', '4']) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '4 / 4',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.confirm));
      break;
    case _OverlayKind.confirm:
      await tester.tap(find.byKey(const Key('toast_confirm_dialog_confirm')));
      break;
  }
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('overlay_result')), findsOneWidget);
}

void main() {
  testWidgets(
    'five operational overlays support localized touch and keyboard workflows',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final fixture in _viewportLocales) {
        for (final kind in _OverlayKind.values) {
          await _pumpHost(tester, kind: kind, fixture: fixture);
          final host = find.byType(_OverlayHost);
          final l10n = AppLocalizations.of(tester.element(host))!;

          await tester.tap(find.byKey(const Key('open_overlay')));
          await tester.pumpAndSettle();

          final dialog = _dialog();
          expect(dialog, findsOneWidget, reason: kind.name);
          expect(find.text(_localizedTitle(kind, l10n)), findsWidgets);
          expect(find.byType(Semantics), findsWidgets);
          _expectVisibleButtonsAreTouchSized(tester, dialog);

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(FocusManager.instance.primaryFocus, isNotNull);
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${kind.name} overflowed at ${fixture.size} '
                '${fixture.locale} with 200% text',
          );

          await _exerciseOverlay(tester, kind, l10n);
          expect(tester.takeException(), isNull, reason: kind.name);
        }
      }
      semantics.dispose();
    },
  );
}
