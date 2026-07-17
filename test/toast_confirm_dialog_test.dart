import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/toast/toast_primitives.dart';

void main() {
  testWidgets('toast confirm dialog lays out and confirms', (tester) async {
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              unawaited(
                ToastConfirmDialog.show(
                  context: context,
                  title: 'Close today',
                  description: 'Save the daily close?',
                  confirmLabel: 'Close',
                ).then((value) => result = value),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final confirm = find.byKey(const Key('toast_confirm_dialog_confirm'));
    expect(confirm, findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });
}
