import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/table_qr_export_service.dart';
import 'package:image/image.dart' as img;

String readRepoFile(String path) => File(path).readAsStringSync();

Map<String, dynamic> qrRow({
  required String tableId,
  required String tableNumber,
  required int order,
  String floor = '1F',
  String token = 'stable-token',
}) {
  return {
    'token_id': '20000000-0000-4000-8000-000000000001',
    'table_id': tableId,
    'table_number': tableNumber,
    'floor_label': floor,
    'layout_sort_order': order,
    'store_name': 'Contract Store',
    'token': '$token-$tableId',
  };
}

class _DisposeTrackingNotifier extends ChangeNotifier {
  _DisposeTrackingNotifier(this.onDispose);

  final VoidCallback onDispose;

  @override
  void dispose() {
    onDispose();
    super.dispose();
  }
}

bool _isWhite(img.Pixel pixel) =>
    pixel.r >= 250 && pixel.g >= 250 && pixel.b >= 250 && pixel.a >= 250;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = TableQrExportService();
  final rows = <Map<String, dynamic>>[
    qrRow(
      tableId: '30000000-0000-4000-8000-000000000003',
      tableNumber: 'VIP/Alpha',
      order: 4,
      floor: '3F',
    ),
    qrRow(
      tableId: '30000000-0000-4000-8000-000000000002',
      tableNumber: 'B-12',
      order: 2,
      floor: '2F',
    ),
    qrRow(
      tableId: '30000000-0000-4000-8000-000000000001',
      tableNumber: 'A-02',
      order: 2,
    ),
  ];

  test('card mapping is canonical, stable, immutable, and absolute HTTPS', () {
    final cards = service.cardsFromRpcRows(
      rows,
      publicBaseUrl: 'https://pos.example.test/admin?ignored=true',
    );

    expect(cards.map((card) => card.tableNumber), [
      'A-02',
      'B-12',
      'VIP/Alpha',
    ]);
    expect(cards.last.floorLabel, '3F');
    expect(cards.last.tableId, rows.first['table_id']);
    expect(cards.last.tableNumber, 'VIP/Alpha');
    expect(
      cards.last.orderUrl,
      startsWith('https://pos.example.test/#/qr/stable-token-'),
    );
    expect(Uri.parse(cards.last.orderUrl).scheme, 'https');
    expect(() => cards.add(cards.first), throwsUnsupportedError);
    expect(TableQrCardModel.scanCopy, hasLength(3));
  });

  test('invalid public URL and incomplete RPC data fail before export', () {
    expect(
      () => service.cardsFromRpcRows(rows, publicBaseUrl: 'http://pos.test'),
      throwsFormatException,
    );
    final incomplete = Map<String, dynamic>.from(rows.first)
      ..remove('table_id');
    expect(
      () => service.cardsFromRpcRows([
        incomplete,
      ], publicBaseUrl: 'https://pos.test'),
      throwsFormatException,
    );
    expect(() => service.buildPdf(const []), throwsStateError);
    expect(() => service.buildPngZip(const []), throwsStateError);
  });

  testWidgets('PNG and ZIP contain exactly one scan-safe card per table', (
    tester,
  ) async {
    final cards = service.cardsFromRpcRows(
      rows,
      publicBaseUrl: 'https://pos.example.test',
    );
    final progress = <TableQrExportProgress>[];
    final zipBytes = await tester.runAsync(
      () => service.buildPngZip(cards, onProgress: progress.add),
    );
    final archive = ZipDecoder().decodeBytes(zipBytes!);

    expect(archive.files, hasLength(cards.length));
    expect(
      archive.files.map((file) => file.name).toSet(),
      hasLength(cards.length),
    );
    expect(progress.map((value) => value.completed), [1, 2, 3]);
    expect(progress.every((value) => value.total == cards.length), isTrue);
    img.Image? firstDecoded;
    for (final file in archive.files) {
      expect(file.name, startsWith('table_qr_'));
      expect(file.name, endsWith('.png'));
      final decoded = img.decodePng(
        Uint8List.fromList(file.content as List<int>),
      );
      expect(decoded, isNotNull);
      expect(decoded!.width, 620);
      expect(decoded.height, 874);
      firstDecoded ??= decoded;
    }
    final png = firstDecoded!;
    final quietZonePixels = <img.Pixel>[
      for (var x = 70; x <= 550; x += 8) png.getPixel(x, 240),
      for (var y = 280; y <= 650; y += 8) png.getPixel(85, y),
      for (var y = 280; y <= 650; y += 8) png.getPixel(535, y),
      for (var x = 70; x <= 550; x += 8) png.getPixel(x, 687),
    ];
    expect(quietZonePixels.where(_isWhite), hasLength(quietZonePixels.length));
    final qrModulePixels = <img.Pixel>[
      for (var y = 270; y <= 650; y += 4)
        for (var x = 118; x <= 502; x += 4) png.getPixel(x, y),
    ];
    expect(
      qrModulePixels.where((pixel) => !_isWhite(pixel)).length,
      greaterThan(100),
    );
    expect(
      archive.files.singleWhere((file) => file.name.contains('VIP_Alpha')).name,
      isNot(contains('/')),
    );
    expect(cards.last.tableNumber, 'VIP/Alpha');
  });

  testWidgets('PDF uses one A6 page per immutable card and vector QR', (
    tester,
  ) async {
    final cards = service.cardsFromRpcRows(
      rows,
      publicBaseUrl: 'https://pos.example.test',
    );
    final progress = <TableQrExportProgress>[];
    final bytes = await tester.runAsync(
      () => service.buildPdf(cards, onProgress: progress.add),
    );
    final text = latin1.decode(bytes!, allowInvalid: true);

    expect(text, startsWith('%PDF'));
    expect(
      RegExp(r'/Type\s*/Page\b').allMatches(text),
      hasLength(cards.length),
    );
    expect(progress.map((value) => value.completed), [1, 2, 3]);
    final source = readRepoFile(
      'lib/core/services/table_qr_export_service.dart',
    );
    expect(source, contains('pageFormat: PdfPageFormat.a6'));
    expect(source, contains('document.addPage('));
    expect(source, contains('pw.Barcode.qrCode()'));
    expect(source, contains('TableQrCardModel.scanCopy'));
    expect(source, isNot(contains('pw.MemoryImage')));
  });

  test(
    '100-table rendering is sequential, ordered, and fails closed',
    () async {
      final hundredRows = List<Map<String, dynamic>>.generate(100, (index) {
        final number = index + 1;
        return qrRow(
          tableId:
              '40000000-0000-4000-8000-${number.toString().padLeft(12, '0')}',
          tableNumber: 'T-${number.toString().padLeft(3, '0')}',
          order: number % 7,
          floor: '${(number % 3) + 1}F',
          token: 'scale-token',
        );
      }).reversed.toList();
      final expectedRows = List<Map<String, dynamic>>.from(hundredRows)
        ..sort((left, right) {
          final orderCompare = (left['layout_sort_order'] as int).compareTo(
            right['layout_sort_order'] as int,
          );
          if (orderCompare != 0) return orderCompare;
          final numberCompare = (left['table_number'] as String).compareTo(
            right['table_number'] as String,
          );
          if (numberCompare != 0) return numberCompare;
          return (left['table_id'] as String).compareTo(
            right['table_id'] as String,
          );
        });

      var activeRenderers = 0;
      var maxActiveRenderers = 0;
      final renderedTables = <String>[];
      final progress = <TableQrExportProgress>[];
      final scaleService = TableQrExportService(
        pngRenderer: (card) async {
          activeRenderers += 1;
          if (activeRenderers > maxActiveRenderers) {
            maxActiveRenderers = activeRenderers;
          }
          renderedTables.add(card.tableNumber);
          await Future<void>.delayed(Duration.zero);
          activeRenderers -= 1;
          return Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]);
        },
      );
      final cards = scaleService.cardsFromRpcRows(
        hundredRows,
        publicBaseUrl: 'https://pos.example.test',
      );
      final zipBytes = await scaleService.buildPngZip(
        cards,
        onProgress: progress.add,
      );
      final archive = ZipDecoder().decodeBytes(zipBytes);

      expect(
        cards.map((card) => card.tableNumber),
        expectedRows.map((row) => row['table_number']),
      );
      expect(renderedTables, cards.map((card) => card.tableNumber));
      expect(maxActiveRenderers, 1);
      expect(archive.files, hasLength(100));
      expect(
        progress.map((value) => value.completed),
        List.generate(100, (i) => i + 1),
      );
      expect(progress.every((value) => value.total == 100), isTrue);

      final failureProgress = <TableQrExportProgress>[];
      final failureOrder = <String>[];
      final failingService = TableQrExportService(
        pngRenderer: (card) async {
          failureOrder.add(card.tableNumber);
          if (failureOrder.length == 42) {
            throw StateError('EXPECTED_RENDER_FAILURE');
          }
          return Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]);
        },
      );
      await expectLater(
        failingService.buildPngZip(cards, onProgress: failureProgress.add),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'EXPECTED_RENDER_FAILURE',
          ),
        ),
      );
      expect(failureOrder, cards.take(42).map((card) => card.tableNumber));
      expect(
        failureProgress.map((value) => value.completed),
        List.generate(41, (i) => i + 1),
      );
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'progress dialog fully tears down after immediate ${fails ? 'failure' : 'success'}',
      (tester) async {
        final dialogKey = GlobalKey();
        Object? caughtError;
        var operationSawMountedDialog = false;
        var notifierDisposed = false;
        var disposedWhileDialogMounted = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => FilledButton(
                key: const Key('start_immediate_operation'),
                onPressed: () async {
                  final notifier = _DisposeTrackingNotifier(() {
                    notifierDisposed = true;
                    disposedWhileDialogMounted =
                        dialogKey.currentContext?.mounted ?? false;
                  });
                  try {
                    await tableQrProgressDialogRunner.run<void>(
                      context: context,
                      notifier: notifier,
                      dialogBuilder: (_) => AlertDialog(
                        key: dialogKey,
                        content: const Text('Working'),
                      ),
                      operation: () async {
                        operationSawMountedDialog =
                            dialogKey.currentContext?.mounted ?? false;
                        if (fails) {
                          throw StateError('IMMEDIATE_FAILURE');
                        }
                      },
                    );
                  } catch (error) {
                    caughtError = error;
                  }
                },
                child: const Text('Start'),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('start_immediate_operation')));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(operationSawMountedDialog, isTrue);
        expect(find.byKey(dialogKey), findsNothing);
        expect(notifierDisposed, isTrue);
        expect(disposedWhileDialogMounted, isFalse);
        if (fails) {
          expect(caughtError, isA<StateError>());
        } else {
          expect(caughtError, isNull);
        }
      },
    );
  }

  test(
    'database RPC reuses active tokens with tenant and concurrency guards',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260717130000_table_qr_batch_export.sql',
      );
      expect(migration, contains('admin_get_or_create_table_qrs'));
      expect(migration, contains('public.require_admin_actor_for_restaurant'));
      expect(migration, contains('extensions.gen_random_bytes(24)'));
      expect(
        migration,
        contains('ON CONFLICT (table_id) WHERE is_active DO NOTHING'),
      );
      final conflictFix = readRepoFile(
        'supabase/migrations/20260722023244_fix_table_qr_batch_conflict.sql',
      );
      expect(
        conflictFix,
        contains(
          'CREATE OR REPLACE FUNCTION public.admin_get_or_create_table_qrs',
        ),
      );
      expect(conflictFix, contains('ON CONFLICT DO NOTHING'));
      expect(
        conflictFix,
        isNot(contains('ON CONFLICT (table_id) WHERE is_active DO NOTHING')),
      );
      expect(
        readRepoFile('scripts/preflight_fix_table_qr_batch_conflict.sql'),
        contains('TABLE_QR_CONFLICT_FIX_PREFLIGHT_OK'),
      );
      expect(
        readRepoFile('scripts/verify_fix_table_qr_batch_conflict.sql'),
        contains('ON CONFLICT DO NOTHING'),
      );
      final returningFix = readRepoFile(
        'supabase/migrations/20260722030603_fix_table_qr_batch_returning.sql',
      );
      expect(
        returningFix,
        contains('INSERT INTO public.table_qr_tokens AS created_token'),
      );
      expect(returningFix, contains('created_token.id'));
      expect(returningFix, contains('created_token.restaurant_id'));
      expect(returningFix, contains('created_token.table_id'));
      expect(returningFix, contains('ON CONFLICT DO NOTHING'));
      expect(
        readRepoFile('scripts/preflight_fix_table_qr_batch_returning.sql'),
        contains('TABLE_QR_RETURNING_FIX_PREFLIGHT_OK'),
      );
      expect(
        readRepoFile('scripts/verify_fix_table_qr_batch_returning.sql'),
        contains('TABLE_QR_RETURNING_FIX_VERIFY_OK'),
      );
      expect(migration, contains('SELECT DISTINCT requested_id'));
      expect(
        migration,
        contains('ORDER BY t.layout_sort_order, t.table_number, t.id'),
      );
      expect(migration, contains('q.table_id = t.id'));
      expect(migration, contains('q.restaurant_id = t.restaurant_id'));
      expect(migration, isNot(contains('UPDATE public.table_qr_tokens')));
      expect(migration, isNot(contains('CREATE TABLE')));
      expect(migration, isNot(contains('ALTER TABLE')));
      expect(migration, isNot(contains('storage.')));
      expect(
        migration,
        contains(
          'REVOKE ALL ON FUNCTION public.admin_get_or_create_table_qrs(uuid, uuid[])',
        ),
      );
      final runtimeContract = readRepoFile(
        'supabase/tests/table_qr_batch_export_contract_test.sql',
      );
      expect(
        runtimeContract,
        contains('ARRAY[v_table_a, v_table_a, v_table_b]'),
      );
      expect(
        runtimeContract,
        contains('TABLE_QR_BATCH_DUPLICATE_INPUT_CREATED_EXTRA_TOKEN'),
      );
    },
  );

  test('admin UI separates stable current/export actions from replacement', () {
    final tables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final tableService = readRepoFile('lib/core/services/tables_service.dart');
    final constants = readRepoFile('lib/core/constants/app_constants.dart');

    expect(tableService, contains("'admin_get_or_create_table_qrs'"));
    expect(tableService, contains("'admin_generate_table_qr'"));
    expect(tables, contains("Key('admin_tables_qr_batch_export_action')"));
    expect(tables, contains("Key('admin_table_qr_pdf_action')"));
    expect(tables, contains("Key('admin_table_qr_png_action')"));
    expect(tables, contains("Key('admin_table_qr_replace_action')"));
    expect(tables, contains('tablesService.generateTableQr(table.id)'));
    expect(tables, isNot(contains('Uri.base')));
    expect(constants, contains("'https://globospossystem.vercel.app'"));
    expect(constants, contains("uri.scheme != 'https'"));
  });

  test('all supported locales and guarded release artifacts are wired', () {
    for (final locale in ['en', 'ko', 'vi']) {
      final arb = readRepoFile('lib/l10n/app_$locale.arb');
      expect(arb, contains('"tablesQrBatchAction"'));
      expect(arb, contains('"tablesQrReplaceWarning"'));
      expect(arb, contains('"tablesQrExportProgress"'));
      expect(arb, contains('"tablesQrExportFailed"'));
    }

    final deploy = readRepoFile('scripts/deploy_pos_production.sh');
    expect(deploy, contains('20260717130000_table_qr_batch_export.sql'));
    expect(deploy, contains('preflight_table_qr_batch_export.sql'));
    expect(deploy, contains('verify_table_qr_batch_export.sql'));
    expect(deploy, contains('rollback_table_qr_batch_export.sql'));
    expect(
      File('scripts/preflight_table_qr_batch_export.sql').existsSync(),
      isTrue,
    );
    expect(
      File('scripts/verify_table_qr_batch_export.sql').existsSync(),
      isTrue,
    );
    expect(
      File('scripts/rollback_table_qr_batch_export.sql').existsSync(),
      isTrue,
    );
    expect(readRepoFile('pubspec.yaml'), contains('archive: ^3.6.1'));
  });
}
