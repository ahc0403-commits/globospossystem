import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_money.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_support.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  const formatter = DirectOrderVndInputFormatter();

  test('editing a middle digit preserves the caret', () {
    final result = formatter.formatEditUpdate(
      const TextEditingValue(text: '181.720'),
      const TextEditingValue(
        text: '171.720',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(result.text, '171.720');
    expect(result.selection.baseOffset, 2);
  });

  test('formatting preserves both endpoints of a reversed selection', () {
    final result = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(
        text: '171720',
        selection: TextSelection(
          baseOffset: 6,
          extentOffset: 2,
          isDirectional: true,
        ),
      ),
    );
    expect(result.text, '171.720');
    expect(result.selection.baseOffset, 7);
    expect(result.selection.extentOffset, 2);
    expect(result.selection.isDirectional, isTrue);
  });

  test('deleting a separator keeps the caret before that separator', () {
    final result = formatter.formatEditUpdate(
      const TextEditingValue(text: '171.720'),
      const TextEditingValue(
        text: '171720',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    expect(result.text, '171.720');
    expect(result.selection.baseOffset, 3);
  });

  test('unfinished mobile composition is left unchanged', () {
    const input = TextEditingValue(
      text: '171720',
      selection: TextSelection.collapsed(offset: 6),
      composing: TextRange(start: 3, end: 6),
    );
    expect(formatter.formatEditUpdate(TextEditingValue.empty, input), input);
    final committed = formatter.formatEditUpdate(
      input,
      input.copyWith(composing: TextRange.empty),
    );
    expect(committed.text, '171.720');
    expect(committed.selection.baseOffset, 7);
  });

  test('pasted separators preserve the numeric amount', () {
    final result = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(
        text: '171,720',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    expect(result.text, '171.720');
    expect(parseDirectOrderVnd(result.text), 171720);
    expect(result.selection.baseOffset, 7);
  });

  test('leading zero normalization preserves the caret relative to digits', () {
    final result = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(
        text: '00171720',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(result.text, '171.720');
    expect(result.selection.baseOffset, 2);
  });

  test('empty values and the existing amount limit remain supported', () {
    expect(
      formatter.formatEditUpdate(
        const TextEditingValue(text: '171.720'),
        TextEditingValue.empty,
      ),
      TextEditingValue.empty,
    );
    const previous = TextEditingValue(
      text: '999.999.999.999',
      selection: TextSelection.collapsed(offset: 15),
    );
    expect(
      formatter.formatEditUpdate(
        previous,
        const TextEditingValue(text: '9999999999999'),
      ),
      previous,
    );
  });

  testWidgets('cashier can correct a digit and confirm the exact amount', (
    tester,
  ) async {
    DirectOrderReceiptReview? receipt;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open_receipt_review'),
              onPressed: () async {
                receipt = await showDirectOrderReceiptReview(context, 171720);
              },
              child: const Text('Review receipt'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_receipt_review')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('direct_actual_received_amount'));
    await tester.enterText(field, '171720');
    final controller = tester.widget<TextField>(field).controller!;

    // Native keyboards report deletion and the next keystroke separately.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '17.720',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    final current = controller.value;
    final caret = current.selection.baseOffset;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: current.text.replaceRange(caret, caret, '0'),
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );
    await tester.pump();
    expect(controller.text, '170.720');

    await tester.enterText(
      find.byKey(const Key('direct_bank_receipt_reference')),
      'bank-fixture',
    );
    await tester.tap(find.byKey(const Key('direct_actual_receipt_verified')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(receipt?.amount, 170720);
  });
}
