import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_requirements.dart';

void main() {
  const pending = DirectOrderRequirement(
    id: 'source',
    version: 1,
    requestText: 'Sauce separate',
    status: 'awaiting_reply',
    sourceLocale: 'en',
  );
  testWidgets('cashier accepts the original request with one tap', (
    tester,
  ) async {
    var accepted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectOrderRequirementCard(
            requirement: pending,
            cashier: true,
            onAccept: () => accepted++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('requirement_accept_source')));
    expect(accepted, 1);
    expect(find.byType(CheckboxListTile), findsNothing);
  });
  testWidgets(
    'changed proposals do not expose acceptance on behalf of customer',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectOrderRequirementCard(
              requirement: const DirectOrderRequirement(
                id: 'proposal',
                version: 2,
                requestText: 'Sauce separate',
                status: 'awaiting_customer',
              ),
              cashier: true,
              onAccept: () {},
            ),
          ),
        ),
      );
      expect(
        find.byKey(const Key('requirement_accept_proposal')),
        findsNothing,
      );
    },
  );
  testWidgets(
    'reply defaults to direct acceptance and a changed proposal is explicit',
    (tester) async {
      DirectOrderRequirementReply? reply;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  reply = await showDialog<DirectOrderRequirementReply>(
                    context: context,
                    builder: (_) => const DirectOrderRequirementReplyDialog(
                      requirement: pending,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final selector = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(selector.selected, {false});
      await tester.tap(find.text('Propose a change'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('requirement_reply_body')),
        'We can offer sauce on the side.',
      );
      await tester.ensureVisible(
        find.byKey(const Key('requirement_reply_submit')),
      );
      await tester.tap(find.byKey(const Key('requirement_reply_submit')));
      await tester.pumpAndSettle();
      expect(reply?.needsConfirmation, true);
    },
  );
}
