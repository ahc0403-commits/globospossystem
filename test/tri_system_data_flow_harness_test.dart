import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

String readOfficeFile(String path) {
  final root =
      Platform.environment['OFFICE_APP_ROOT'] ??
      '/Users/andreahn/Documents/restaurant_office_app';
  final file = File('$root/$path');
  if (!file.existsSync()) {
    fail('Missing Office fixture file: ${file.path}');
  }
  return file.readAsStringSync();
}

void main() {
  group('tri-system Deliberry -> POS -> Office data flow harness', () {
    test('static contracts keep all three systems wired through read fences', () {
      final posSalesView =
          readRepoFile(
            'supabase/migrations/20260604000000_office_pos_sales_events.sql',
          ) +
          readRepoFile(
            'supabase/migrations/20260604001000_pos_payment_refund_void_adjustments.sql',
          ) +
          readRepoFile(
            'supabase/migrations/20260609000000_office_pos_sales_photo_objet_events.sql',
          );
      final deliberrySettlementFunction = readRepoFile(
        'supabase/functions/generate_delivery_settlement/index.ts',
      );
      final legacySettlementFunction = readRepoFile(
        'supabase/functions/generate-settlement/index.ts',
      );
      final officeBridge = readOfficeFile(
        'supabase/functions/pos-bridge/index.ts',
      );
      final officePosService = readOfficeFile(
        'lib/app/api/pos_data_service.dart',
      );
      final officeImport = readOfficeFile(
        'supabase/migrations/472_pos_sales_event_import_and_bucket_posting.sql',
      );
      final officeRepository = readOfficeFile(
        'lib/features/pos_sales/data/pos_sales_repository.dart',
      );

      expect(posSalesView, contains("'external_sales'::text as source_table"));
      expect(
        posSalesView,
        contains("'payment_adjustments'::text as source_table"),
      );
      expect(posSalesView, contains("('payment_adjustment:' || pa.id::text)"));
      expect(posSalesView, contains('pa.adjustment_type as event_type'));
      expect(posSalesView, contains('(-pa.amount)::numeric(15,2)'));
      expect(posSalesView, contains('record_payment_adjustment'));
      expect(posSalesView, contains('PAYMENT_ADJUSTMENTS_IMMUTABLE'));
      expect(posSalesView, contains("('external_sale:' || es.id::text)"));
      expect(
        posSalesView,
        contains("'photo_objet_sales'::text as source_table"),
      );
      expect(
        posSalesView,
        contains("('photo_objet_sales:' || po.id::text || ':sale')"),
      );
      expect(
        posSalesView,
        contains("('photo_objet_sales:' || po.id::text || ':service')"),
      );
      expect(
        posSalesView,
        contains('coalesce(po.gross_sales, 0)::numeric(15,2)'),
      );
      expect(
        posSalesView,
        contains('coalesce(po.service_amount, 0)::numeric(15,2)'),
      );
      expect(posSalesView, contains("'pay'::text as payment_bucket"));
      expect(
        posSalesView,
        contains("when es.order_status = 'cancelled' then 0"),
      );
      expect(
        posSalesView,
        contains("when es.order_status in ('refunded', 'partially_refunded')"),
      );
      expect(
        posSalesView,
        contains('grant select on public.v_office_pos_sales_events'),
      );
      expect(
        posSalesView,
        contains('grant select on public.v_office_pos_sales_bucket_summary'),
      );
      expect(posSalesView, contains('to authenticated, service_role'));
      expect(
        posSalesView,
        contains('sum(transaction_count)::integer as transaction_count'),
      );
      expect(posSalesView, contains('count(*)::integer as event_count'));

      expect(deliberrySettlementFunction, contains(".from('external_sales')"));
      expect(
        deliberrySettlementFunction,
        contains(".from('delivery_settlements')"),
      );
      expect(
        deliberrySettlementFunction,
        contains("source_system: 'deliberry'"),
      );
      expect(
        deliberrySettlementFunction,
        contains(".update({ settlement_id: settlement.id })"),
      );
      expect(
        legacySettlementFunction,
        contains('.from("delivery_settlements")'),
      );
      expect(
        legacySettlementFunction,
        contains('.eq("source_system", "deliberry")'),
      );
      expect(legacySettlementFunction, contains('SETTLEMENT_ALREADY_EXISTS'));

      expect(
        officeBridge,
        contains('case "pos_sales_events_for_reconciliation"'),
      );
      expect(
        officeBridge,
        contains('await fetchPosRows("v_office_pos_sales_events"'),
      );
      expect(officeBridge, contains('case "pos_sales_bucket_summary"'));
      expect(
        officeBridge,
        contains('await fetchPosRows("v_office_pos_sales_bucket_summary"'),
      );
      expect(officeBridge, contains('pos_store_id: posStoreId'));
      expect(officeBridge, contains('store_id: scope.officeStoreId'));
      expect(officeBridge, contains('brand_id: scope.brandId'));

      expect(
        officePosService,
        contains("'pos_sales_events_for_reconciliation'"),
      );
      expect(officePosService, contains("'daily_sales_bucket_summary'"));
      expect(officeRepository, contains("'import_pos_sales_events'"));
      expect(officeRepository, contains("'post_pos_sales_source_v2'"));

      expect(
        officeImport,
        contains('constraint pos_sales_events_event_key_unique'),
      );
      expect(
        officeImport,
        contains('constraint pos_sales_events_amount_source_check'),
      );
      expect(
        officeImport,
        contains('accounting.prevent_pos_sales_events_mutation()'),
      );
      expect(officeImport, contains('POS_SALES_EVENTS_SCOPE_MISMATCH'));
      expect(
        officeImport,
        contains("event_type in ('sale', 'refund', 'void')"),
      );
      expect(
        officeImport,
        contains("source_table in ('daily_sales', 'daily_sales_adjustment')"),
      );
    });

    test('synthetic Deliberry facts survive POS bridge and Office import', () {
      final fixture = _TriSystemFixture();
      final posEvents = fixture.projectPosOfficeEvents();

      final bridgeEvents = _filterForOfficeBridge(
        posEvents,
        brandId: fixture.brandId,
        storeId: fixture.storeId,
        saleDate: fixture.saleDate,
      );

      expect(
        bridgeEvents.map((event) => event.eventKey),
        orderedEquals([
          'external_sale:11111111-1111-4111-8111-111111111111',
          'external_sale:22222222-2222-4222-8222-222222222222',
          'external_sale:33333333-3333-4333-8333-333333333333',
        ]),
      );
      expect(
        bridgeEvents.every((event) => event.sourceTable == 'external_sales'),
        isTrue,
      );
      expect(
        bridgeEvents.every((event) => event.paymentBucket == 'pay'),
        isTrue,
      );
      expect(
        bridgeEvents.every((event) => event.brandId == fixture.brandId),
        isTrue,
      );
      expect(
        bridgeEvents.every((event) => event.storeId == fixture.storeId),
        isTrue,
      );
      expect(
        bridgeEvents.any((event) => event.storeId == fixture.otherStoreId),
        isFalse,
        reason:
            'Office bridge must not leak another store into this import batch.',
      );

      final byEventType = {
        for (final event in bridgeEvents) event.eventType: event,
      };
      expect(byEventType['sale']!.signedAmount, 95000);
      expect(byEventType['sale']!.grossAmount, 100000);
      expect(byEventType['refund']!.signedAmount, -12000);
      expect(byEventType['refund']!.grossAmount, 70000);
      expect(byEventType['cancel']!.signedAmount, 0);
      expect(byEventType['cancel']!.grossAmount, 0);

      final summary = _bucketSummary(bridgeEvents);
      expect(summary.length, 1);
      expect(summary.single.paymentBucket, 'pay');
      expect(summary.single.grossSales, 170000);
      expect(summary.single.salesAmount, 95000);
      expect(summary.single.refundAmount, 12000);
      expect(summary.single.netSales, 83000);
      expect(summary.single.saleCount, 1);
      expect(summary.single.refundCount, 1);
      expect(summary.single.cancelCount, 1);

      final officeImport = _OfficeImportSimulator();
      final firstImport = officeImport.importEvents(
        brandId: fixture.brandId,
        storeId: fixture.storeId,
        saleDate: fixture.saleDate,
        events: bridgeEvents,
      );

      expect(firstImport.inputCount, 3);
      expect(firstImport.insertedCount, 3);
      expect(firstImport.skippedCount, 0);
      expect(firstImport.financialEventCount, 2);
      expect(firstImport.amount, 83000);
      expect(firstImport.createdPostingSource, isTrue);

      final importedRows = officeImport.rows;
      expect(importedRows.length, 3);
      expect(
        importedRows
            .where(
              (row) => row.eventType == 'sale' || row.eventType == 'refund',
            )
            .every((row) => row.postingSourceId != null),
        isTrue,
      );
      expect(
        importedRows
            .singleWhere((row) => row.eventType == 'cancel')
            .postingSourceId,
        isNull,
        reason: 'Cancel rows remain immutable non-financial facts in Office.',
      );

      final secondImport = officeImport.importEvents(
        brandId: fixture.brandId,
        storeId: fixture.storeId,
        saleDate: fixture.saleDate,
        events: bridgeEvents,
      );

      expect(secondImport.insertedCount, 0);
      expect(secondImport.skippedCount, 3);
      expect(secondImport.existingCount, 3);
      expect(officeImport.rows.length, 3);
    });

    test('scope mismatch and cross-store contamination fail closed', () {
      final fixture = _TriSystemFixture();
      final posEvents = fixture.projectPosOfficeEvents();
      final targetEvents = _filterForOfficeBridge(
        posEvents,
        brandId: fixture.brandId,
        storeId: fixture.storeId,
        saleDate: fixture.saleDate,
      );
      final leakedEvent = posEvents.singleWhere(
        (event) => event.storeId == fixture.otherStoreId,
      );

      expect(targetEvents.length, 3);
      expect(leakedEvent.eventKey, startsWith('external_sale:'));

      final officeImport = _OfficeImportSimulator();
      expect(
        () => officeImport.importEvents(
          brandId: fixture.brandId,
          storeId: fixture.storeId,
          saleDate: fixture.saleDate,
          events: [...targetEvents, leakedEvent],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('POS_SALES_EVENTS_SCOPE_MISMATCH'),
          ),
        ),
      );

      expect(
        () => officeImport.importEvents(
          brandId: fixture.brandId,
          storeId: fixture.storeId,
          saleDate: fixture.saleDate,
          events: [targetEvents.first, targetEvents.first],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('DUPLICATE_EVENT_KEY_IN_BATCH'),
          ),
        ),
      );
      expect(officeImport.rows, isEmpty);
    });
  });
}

class _TriSystemFixture {
  final brandId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  final storeId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  final otherStoreId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  final saleDate = DateTime.utc(2026, 6, 4);

  List<_ExternalSaleRow> get externalSales => [
    _ExternalSaleRow(
      id: '11111111-1111-4111-8111-111111111111',
      brandId: brandId,
      storeId: storeId,
      sourceSystem: 'deliberry',
      externalOrderId: 'DLB-HARNESS-001',
      orderStatus: 'completed',
      grossAmount: 100000,
      netAmount: 95000,
      isRevenue: true,
      occurredAt: DateTime.utc(2026, 6, 4, 1),
    ),
    _ExternalSaleRow(
      id: '22222222-2222-4222-8222-222222222222',
      brandId: brandId,
      storeId: storeId,
      sourceSystem: 'deliberry',
      externalOrderId: 'DLB-HARNESS-002',
      orderStatus: 'partially_refunded',
      grossAmount: 70000,
      netAmount: 60000,
      isRevenue: true,
      occurredAt: DateTime.utc(2026, 6, 4, 2),
      payload: {'refund_amount': '12000'},
    ),
    _ExternalSaleRow(
      id: '33333333-3333-4333-8333-333333333333',
      brandId: brandId,
      storeId: storeId,
      sourceSystem: 'deliberry',
      externalOrderId: 'DLB-HARNESS-003',
      orderStatus: 'cancelled',
      grossAmount: 50000,
      netAmount: 0,
      isRevenue: false,
      occurredAt: DateTime.utc(2026, 6, 4, 3),
    ),
    _ExternalSaleRow(
      id: '44444444-4444-4444-8444-444444444444',
      brandId: brandId,
      storeId: otherStoreId,
      sourceSystem: 'deliberry',
      externalOrderId: 'DLB-HARNESS-OTHER-STORE',
      orderStatus: 'completed',
      grossAmount: 90000,
      netAmount: 88000,
      isRevenue: true,
      occurredAt: DateTime.utc(2026, 6, 4, 4),
    ),
  ];

  List<_PosOfficeEvent> projectPosOfficeEvents() {
    return externalSales.map(_projectExternalSale).toList(growable: false)
      ..sort((a, b) {
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        if (byTime != 0) return byTime;
        return a.eventKey.compareTo(b.eventKey);
      });
  }
}

class _ExternalSaleRow {
  _ExternalSaleRow({
    required this.id,
    required this.brandId,
    required this.storeId,
    required this.sourceSystem,
    required this.externalOrderId,
    required this.orderStatus,
    required this.grossAmount,
    required this.netAmount,
    required this.isRevenue,
    required this.occurredAt,
    this.payload = const {},
  });

  final String id;
  final String brandId;
  final String storeId;
  final String sourceSystem;
  final String externalOrderId;
  final String orderStatus;
  final num grossAmount;
  final num netAmount;
  final bool isRevenue;
  final DateTime occurredAt;
  final Map<String, String> payload;
}

class _PosOfficeEvent {
  _PosOfficeEvent({
    required this.eventKey,
    required this.sourceTable,
    required this.sourceId,
    required this.brandId,
    required this.storeId,
    required this.saleDate,
    required this.occurredAt,
    required this.paymentBucket,
    required this.eventType,
    required this.signedAmount,
    required this.grossAmount,
    required this.serviceAmount,
    required this.transactionCount,
    required this.rawMethod,
  });

  final String eventKey;
  final String sourceTable;
  final String sourceId;
  final String brandId;
  final String storeId;
  final DateTime saleDate;
  final DateTime occurredAt;
  final String paymentBucket;
  final String eventType;
  final num signedAmount;
  final num grossAmount;
  final num serviceAmount;
  final int transactionCount;
  final String rawMethod;
}

class _BucketSummary {
  _BucketSummary({
    required this.paymentBucket,
    required this.grossSales,
    required this.salesAmount,
    required this.refundAmount,
    required this.netSales,
    required this.saleCount,
    required this.refundCount,
    required this.cancelCount,
  });

  final String paymentBucket;
  final num grossSales;
  final num salesAmount;
  final num refundAmount;
  final num netSales;
  final int saleCount;
  final int refundCount;
  final int cancelCount;
}

class _OfficeImportResult {
  _OfficeImportResult({
    required this.inputCount,
    required this.insertedCount,
    required this.skippedCount,
    required this.existingCount,
    required this.financialEventCount,
    required this.amount,
    required this.createdPostingSource,
  });

  final int inputCount;
  final int insertedCount;
  final int skippedCount;
  final int existingCount;
  final int financialEventCount;
  final num amount;
  final bool createdPostingSource;
}

class _OfficeImportedRow {
  _OfficeImportedRow({
    required this.eventKey,
    required this.eventType,
    required this.signedAmount,
    required this.postingSourceId,
  });

  final String eventKey;
  final String eventType;
  final num signedAmount;
  final String? postingSourceId;
}

class _OfficeImportSimulator {
  final Map<String, _OfficeImportedRow> _rowsByEventKey = {};

  List<_OfficeImportedRow> get rows => _rowsByEventKey.values.toList();

  _OfficeImportResult importEvents({
    required String brandId,
    required String storeId,
    required DateTime saleDate,
    required List<_PosOfficeEvent> events,
  }) {
    final batchKeys = <String>{};
    for (final event in events) {
      if (!batchKeys.add(event.eventKey)) {
        throw StateError('DUPLICATE_EVENT_KEY_IN_BATCH: ${event.eventKey}');
      }
      if (event.brandId != brandId ||
          event.storeId != storeId ||
          !_sameDate(event.saleDate, saleDate)) {
        throw StateError('POS_SALES_EVENTS_SCOPE_MISMATCH: ${event.eventKey}');
      }
    }

    final newEvents = events
        .where((event) => !_rowsByEventKey.containsKey(event.eventKey))
        .toList(growable: false);
    final financialEvents = newEvents
        .where(_isFinancialPostingEvent)
        .toList(growable: false);
    final amount = financialEvents.fold<num>(
      0,
      (sum, event) => sum + event.signedAmount,
    );
    final postingSourceId = financialEvents.isNotEmpty
        ? 'posting-source:$brandId/$storeId/${_dateKey(saleDate)}'
        : null;

    for (final event in newEvents) {
      _rowsByEventKey[event.eventKey] = _OfficeImportedRow(
        eventKey: event.eventKey,
        eventType: event.eventType,
        signedAmount: event.signedAmount,
        postingSourceId: _isFinancialPostingEvent(event)
            ? postingSourceId
            : null,
      );
    }

    return _OfficeImportResult(
      inputCount: events.length,
      insertedCount: newEvents.length,
      skippedCount: events.length - newEvents.length,
      existingCount: events.length - newEvents.length,
      financialEventCount: financialEvents.length,
      amount: amount.abs(),
      createdPostingSource: postingSourceId != null,
    );
  }
}

_PosOfficeEvent _projectExternalSale(_ExternalSaleRow row) {
  final eventType = switch (row.orderStatus) {
    'refunded' || 'partially_refunded' => 'refund',
    'cancelled' => 'cancel',
    _ => 'sale',
  };
  final signedAmount = switch (row.orderStatus) {
    'refunded' => -row.netAmount,
    'partially_refunded' => -_readRefundAmount(row.payload),
    'cancelled' => 0,
    _ => row.isRevenue ? row.netAmount : 0,
  };
  final grossAmount =
      (row.orderStatus == 'completed' ||
              row.orderStatus == 'partially_refunded') &&
          row.isRevenue
      ? row.grossAmount
      : 0;

  return _PosOfficeEvent(
    eventKey: 'external_sale:${row.id}',
    sourceTable: 'external_sales',
    sourceId: row.id,
    brandId: row.brandId,
    storeId: row.storeId,
    saleDate: DateTime.utc(
      row.occurredAt.year,
      row.occurredAt.month,
      row.occurredAt.day,
    ),
    occurredAt: row.occurredAt,
    paymentBucket: 'pay',
    eventType: eventType,
    signedAmount: signedAmount,
    grossAmount: grossAmount,
    serviceAmount: 0,
    transactionCount: 1,
    rawMethod: row.sourceSystem,
  );
}

num _readRefundAmount(Map<String, String> payload) {
  for (final key in ['refund_amount', 'refunded_amount']) {
    final raw = payload[key];
    if (raw == null) continue;
    final parsed = num.tryParse(raw);
    if (parsed != null) return parsed;
  }
  return 0;
}

List<_PosOfficeEvent> _filterForOfficeBridge(
  List<_PosOfficeEvent> events, {
  required String brandId,
  required String storeId,
  required DateTime saleDate,
}) {
  return events
      .where(
        (event) =>
            event.brandId == brandId &&
            event.storeId == storeId &&
            _sameDate(event.saleDate, saleDate),
      )
      .toList(growable: false);
}

List<_BucketSummary> _bucketSummary(List<_PosOfficeEvent> events) {
  final buckets = <String, List<_PosOfficeEvent>>{};
  for (final event in events) {
    buckets.putIfAbsent(event.paymentBucket, () => []).add(event);
  }
  return buckets.entries
      .map((entry) {
        final bucketEvents = entry.value;
        return _BucketSummary(
          paymentBucket: entry.key,
          grossSales: bucketEvents.fold<num>(
            0,
            (sum, event) => sum + event.grossAmount,
          ),
          salesAmount: bucketEvents
              .where((event) => event.eventType == 'sale')
              .fold<num>(0, (sum, event) => sum + event.signedAmount),
          refundAmount: bucketEvents
              .where((event) => event.eventType == 'refund')
              .fold<num>(0, (sum, event) => sum + event.signedAmount)
              .abs(),
          netSales: bucketEvents.fold<num>(
            0,
            (sum, event) => sum + event.signedAmount,
          ),
          saleCount: bucketEvents
              .where((event) => event.eventType == 'sale')
              .length,
          refundCount: bucketEvents
              .where((event) => event.eventType == 'refund')
              .length,
          cancelCount: bucketEvents
              .where((event) => event.eventType == 'cancel')
              .length,
        );
      })
      .toList(growable: false)
    ..sort((a, b) => a.paymentBucket.compareTo(b.paymentBucket));
}

bool _isFinancialPostingEvent(_PosOfficeEvent event) {
  return {'sale', 'refund', 'void'}.contains(event.eventType) &&
      event.signedAmount != 0;
}

bool _sameDate(DateTime left, DateTime right) =>
    _dateKey(left) == _dateKey(right);

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
