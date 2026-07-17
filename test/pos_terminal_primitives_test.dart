import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/pos_design_tokens.dart';
import 'package:globos_pos_system/core/ui/pos_terminal_primitives.dart';

Widget _wrap(Widget child, {double width = 1200, double height = 760}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: width, height: height, child: child),
    ),
  );
}

void main() {
  // -----------------------------------------------------------------------
  // Existing primitive smoke tests (preserved from V1)
  // -----------------------------------------------------------------------
  testWidgets('POS terminal primitives render with stable labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        PosTerminalShell(
          title: 'Payment Terminal',
          subtitle: 'Cashier',
          trailing: const Text('Store'),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    PosStatusFilterBar(
                      items: [
                        PosStatusFilterItem(
                          label: 'All',
                          selected: true,
                          onTap: () {},
                        ),
                        PosStatusFilterItem(
                          label: 'Ready',
                          selected: false,
                          onTap: () {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const PosMoneyBlock(
                      label: 'Amount due',
                      amount: '157,500₫',
                    ),
                    const SizedBox(height: 12),
                    PosActionPad(
                      items: [
                        PosActionPadItem(
                          label: 'Cash',
                          selected: true,
                          onTap: () {},
                        ),
                        PosActionPadItem(label: 'Card', onTap: () {}),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              PosInspectorPanel(
                title: 'Selected T12',
                subtitle: '3 guests',
                primaryAction: FilledButton(
                  onPressed: () {},
                  child: const Text('Confirm'),
                ),
                children: const [Text('Pho Bo'), Text('Ca Phe Sua')],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Payment Terminal'), findsOneWidget);
    expect(find.text('157,500₫'), findsOneWidget);
    expect(find.text('Selected T12'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
  });

  testWidgets('POS ticket and floor map primitives render', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            Expanded(
              child: PosTicketCard(
                orderLabel: '#1025',
                tableLabel: 'T12',
                elapsedLabel: '15 min',
                statusLabel: 'New',
                statusColor: Colors.redAccent,
                actionLabel: 'Start',
                onAction: () {},
                lines: const [
                  PosTicketLine(quantity: '1', label: 'Pho Bo'),
                  PosTicketLine(quantity: '2', label: 'Ca Phe Sua'),
                ],
              ),
            ),
            Expanded(
              child: PosFloorMapSurface(
                child: Center(
                  child: Container(width: 120, height: 64, color: Colors.blue),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('#1025'), findsOneWidget);
    expect(find.text('Pho Bo'), findsOneWidget);
  });

  // -----------------------------------------------------------------------
  // Phase 0 V2 — token existence assertions
  // -----------------------------------------------------------------------
  group('Phase 0 token contracts', () {
    test('PosSurfaceRole exposes all seven named roles', () {
      final roles = <PosSurfaceRole>[
        PosSurfaceRole.background,
        PosSurfaceRole.operating,
        PosSurfaceRole.action,
        PosSurfaceRole.selected,
        PosSurfaceRole.danger,
        PosSurfaceRole.disabled,
        PosSurfaceRole.processing,
      ];
      for (final r in roles) {
        expect(r.fill, isA<Color>());
        expect(r.stroke, isA<Color>());
        expect(r.text, isA<Color>());
        expect(r.helper, isA<Color>());
      }
    });

    test('PosNumericText styles include tabular figures', () {
      final styles = <TextStyle>[
        PosNumericText.amountHero,
        PosNumericText.amountDue,
        PosNumericText.amountLarge,
        PosNumericText.amountLine,
        PosNumericText.amountCompact,
        PosNumericText.tableId,
        PosNumericText.orderId,
        PosNumericText.elapsedPrimary,
        PosNumericText.elapsedOverdue,
        PosNumericText.qtyUnit,
        PosNumericText.unitPrice,
        PosNumericText.lineAmount,
      ];
      for (final style in styles) {
        expect(style.fontFeatures, isNotNull);
        expect(
          style.fontFeatures!.any(
            (f) => f == const FontFeature.tabularFigures(),
          ),
          isTrue,
          reason: '$style should include tabularFigures',
        );
        expect(
          style.letterSpacing,
          isNot(lessThan(0)),
          reason: 'no negative letterSpacing',
        );
      }
    });

    test('PosTouchStateTokens define all required states', () {
      expect(PosTouchStateTokens.pressedOverlayOpacity, greaterThan(0));
      expect(
        PosTouchStateTokens.pressedDuration.inMilliseconds,
        greaterThan(0),
      );
      expect(PosTouchStateTokens.selectedBorderWidth, greaterThan(0));
      expect(PosTouchStateTokens.disabledOpacity, greaterThan(0));
      expect(PosTouchStateTokens.disabledOpacity, lessThan(1));
      expect(PosTouchStateTokens.processingOverlayOpacity, greaterThan(0));
      expect(
        PosTouchStateTokens.processingMinDuration.inMilliseconds,
        greaterThan(0),
      );
      expect(
        PosTouchStateTokens.destructiveConfirmTimeout.inSeconds,
        greaterThan(0),
      );
      expect(PosTouchStateTokens.destructiveArmedBorderWidth, greaterThan(0));
      expect(PosTouchStateTokens.offlineBlockedOpacity, greaterThan(0));
      expect(PosTouchStateTokens.offlineBlockedOpacity, lessThan(1));
    });

    test('PosDensity.touchTargetMin is 48', () {
      expect(PosDensity.touchTargetMin, 48);
    });

    test('PosNumericText.amountHero is the largest numeric style', () {
      expect(
        PosNumericText.amountHero.fontSize!,
        greaterThan(PosNumericText.amountDue.fontSize!),
      );
    });

    test('PosNumericText.elapsedOverdue is larger than elapsedPrimary', () {
      expect(
        PosNumericText.elapsedOverdue.fontSize!,
        greaterThan(PosNumericText.elapsedPrimary.fontSize!),
      );
    });
  });

  // -----------------------------------------------------------------------
  // Phase 0 V2 — PosActionTile
  // -----------------------------------------------------------------------
  group('PosActionTile', () {
    testWidgets('renders label and helper', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PosActionTile(
            label: 'Tiền mặt',
            helper: 'Cash payment',
            icon: Icons.money,
          ),
        ),
      );
      expect(find.text('Tiền mặt'), findsOneWidget);
      expect(find.text('Cash payment'), findsOneWidget);
      expect(find.byIcon(Icons.money), findsOneWidget);
    });

    testWidgets('meets 48px minimum touch target', (tester) async {
      await tester.pumpWidget(_wrap(const PosActionTile(label: 'A')));
      final box = tester.renderObject<RenderBox>(
        find.byType(AnimatedContainer),
      );
      expect(box.size.height, greaterThanOrEqualTo(PosDensity.touchTargetMin));
    });

    testWidgets('shows spinner in processing state', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PosActionTile(
            label: 'Processing',
            state: PosActionTileState.processing,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('does not fire onTap when disabled', (tester) async {
      var fired = false;
      await tester.pumpWidget(
        _wrap(
          PosActionTile(
            label: 'Disabled',
            state: PosActionTileState.disabled,
            onTap: () => fired = true,
          ),
        ),
      );
      await tester.tap(find.byType(PosActionTile));
      expect(fired, isFalse);
    });

    testWidgets('does not fire onTap when offlineBlocked', (tester) async {
      var fired = false;
      await tester.pumpWidget(
        _wrap(
          PosActionTile(
            label: 'Offline',
            state: PosActionTileState.offlineBlocked,
            onTap: () => fired = true,
          ),
        ),
      );
      await tester.tap(find.byType(PosActionTile));
      expect(fired, isFalse);
    });

    testWidgets('fires onTap in idle state', (tester) async {
      var fired = false;
      await tester.pumpWidget(
        _wrap(PosActionTile(label: 'Active', onTap: () => fired = true)),
      );
      await tester.tap(find.byType(PosActionTile));
      expect(fired, isTrue);
    });

    testWidgets('long KO/VI/EN labels do not overflow', (tester) async {
      for (final label in [
        '결제 방법을 선택하시고 확인 버튼을 눌러주세요',
        'Vui lòng chọn phương thức thanh toán và nhấn xác nhận',
        'Please select a payment method and confirm your choice now',
      ]) {
        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 200,
              child: PosActionTile(label: label, helper: label),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'overflow for: $label');
      }
    });
  });

  // -----------------------------------------------------------------------
  // Phase 0 V2 — PosAmountAnchor
  // -----------------------------------------------------------------------
  group('PosAmountAnchor', () {
    testWidgets('renders label, amount, and helper', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PosAmountAnchor(
            label: '결제 금액',
            amount: '12,345,000₫',
            helper: 'VAT included',
          ),
        ),
      );
      expect(find.text('결제 금액'), findsOneWidget);
      expect(find.text('12,345,000₫'), findsOneWidget);
      expect(find.text('VAT included'), findsOneWidget);
    });

    testWidgets('renders long VND amounts without throwing', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PosAmountAnchor(label: 'Tổng cộng', amount: '999,999,999,999₫'),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('999,999,999,999₫'), findsOneWidget);
    });

    testWidgets('accepts custom surface role', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PosAmountAnchor(
            label: 'Due',
            amount: '50,000₫',
            role: PosSurfaceRole.danger,
          ),
        ),
      );
      expect(find.text('50,000₫'), findsOneWidget);
    });

    testWidgets('meets minimum anchor height', (tester) async {
      await tester.pumpWidget(
        _wrap(const PosAmountAnchor(label: 'Total', amount: '0₫')),
      );
      final box = tester.renderObject<RenderBox>(find.byType(PosAmountAnchor));
      expect(
        box.size.height,
        greaterThanOrEqualTo(PosDensity.amountAnchorMinHeight),
      );
    });
  });

  // -----------------------------------------------------------------------
  // Phase 0 V2 — PosDestructiveButton
  // -----------------------------------------------------------------------
  group('PosDestructiveButton', () {
    testWidgets('requires two taps before firing callback', (tester) async {
      var confirmCount = 0;
      await tester.pumpWidget(
        _wrap(
          PosDestructiveButton(
            idleLabel: 'Cancel order',
            armedLabel: 'Confirm cancel?',
            onConfirm: () => confirmCount++,
            icon: Icons.cancel,
          ),
        ),
      );

      expect(find.text('Cancel order'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);

      await tester.tap(find.byType(PosDestructiveButton));
      await tester.pump();
      expect(confirmCount, 0);
      expect(find.text('Confirm cancel?'), findsOneWidget);

      await tester.tap(find.byType(PosDestructiveButton));
      await tester.pump();
      expect(confirmCount, 1);
      expect(find.text('Cancel order'), findsOneWidget);
    });

    testWidgets('auto-disarms after timeout', (tester) async {
      var confirmCount = 0;
      await tester.pumpWidget(
        _wrap(
          PosDestructiveButton(
            idleLabel: 'Void',
            armedLabel: 'Confirm void?',
            onConfirm: () => confirmCount++,
          ),
        ),
      );

      await tester.tap(find.byType(PosDestructiveButton));
      await tester.pump();
      expect(find.text('Confirm void?'), findsOneWidget);

      await tester.pump(
        PosTouchStateTokens.destructiveConfirmTimeout +
            const Duration(milliseconds: 100),
      );
      expect(find.text('Void'), findsOneWidget);
      expect(confirmCount, 0);
    });

    testWidgets('long KO/VI labels do not overflow', (tester) async {
      for (final label in [
        '주문을 완전히 취소하시겠습니까?',
        'Bạn có chắc chắn muốn hủy đơn hàng không?',
      ]) {
        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 250,
              child: PosDestructiveButton(
                idleLabel: label,
                armedLabel: label,
                onConfirm: () {},
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'overflow: $label');
      }
    });
  });
}
