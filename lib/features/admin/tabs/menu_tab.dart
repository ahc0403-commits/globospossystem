import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../menu_import/menu_excel_import.dart';
import '../menu_import/menu_excel_roundtrip.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/menu_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

typedef MenuImportFilePicker = Future<XFile?> Function();
typedef MenuExportFileSaver =
    Future<void> Function(String fileName, Uint8List bytes);

class MenuTab extends ConsumerStatefulWidget {
  const MenuTab({super.key, this.pickImportFile, this.saveExportFile});

  final MenuImportFilePicker? pickImportFile;
  final MenuExportFileSaver? saveExportFile;

  @override
  ConsumerState<MenuTab> createState() => _MenuTabState();
}

class _MenuTabState extends ConsumerState<MenuTab> {
  String? _lastError;
  bool _isImportFlowActive = false;
  bool _isImporting = false;
  bool _isExporting = false;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final storeId = ref.watch(authProvider).storeId;
    if (storeId == null) {
      return const _RestaurantMissingView(key: Key('admin_menu_root'));
    }

    final menuState = ref.watch(menuProvider(storeId));
    final menuNotifier = ref.read(menuProvider(storeId).notifier);
    final auditTraceAsync = ref.watch(adminAuditTraceProvider(storeId));
    final numberFormat = NumberFormat('#,###', 'vi_VN');

    final categoriesAsync = menuState.categories;
    final itemsAsync = menuState.items;

    if (menuState.error != null &&
        menuState.error!.isNotEmpty &&
        menuState.error != _lastError) {
      _lastError = menuState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, menuState.error!);
        }
      });
    }

    final isLoading = categoriesAsync.isLoading || itemsAsync.isLoading;
    final categoriesError = categoriesAsync.hasError;
    final itemsError = itemsAsync.hasError;

    if (isLoading) {
      return const Scaffold(
        key: Key('admin_menu_root'),
        backgroundColor: AppColors.surface0,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (categoriesError || itemsError) {
      return Scaffold(
        key: const Key('admin_menu_root'),
        backgroundColor: AppColors.surface0,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.menuLoadFailed,
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: menuNotifier.fetchAll,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    final categories = categoriesAsync.valueOrNull ?? [];
    final allItems = itemsAsync.valueOrNull ?? [];
    final selectedCategoryId = menuState.selectedCategoryId;

    final selectedItems = selectedCategoryId == null
        ? <Map<String, dynamic>>[]
        : allItems
              .where(
                (item) => item['category_id']?.toString() == selectedCategoryId,
              )
              .toList();
    final availableItems = allItems
        .where((item) => item['is_available'] == true)
        .length;

    final header = _buildMenuCommandHeader(
      categoryCount: categories.length,
      itemCount: allItems.length,
      availableItems: availableItems,
      selectedItemCount: selectedItems.length,
      selectedCategoryName: _categoryNameForId(categories, selectedCategoryId),
      onExportExcel: _isImportFlowActive || _isExporting
          ? null
          : () => _exportMenuWorkbook(storeId, categories, allItems),
      onImportExcel: _isImportFlowActive || _isExporting
          ? null
          : () => _importMenuWorkbook(storeId, menuNotifier),
      onImportFilesDropped: _isImportFlowActive || _isExporting
          ? null
          : (files) => _importDroppedMenuWorkbook(files, storeId, menuNotifier),
      onAddCategory: () => _showAddCategoryDialog(context, menuNotifier),
      onAddItem: selectedCategoryId == null
          ? null
          : () => _showAddItemDialog(
              context,
              selectedCategoryId,
              allItems,
              menuNotifier,
            ),
    );

    Widget categoryPane({required bool scrollable}) => _CategoryPanel(
      categories: categories,
      selectedCategoryId: selectedCategoryId,
      itemCountsByCategory: {
        for (final category in categories)
          category['id'].toString(): allItems
              .where(
                (item) =>
                    item['category_id']?.toString() ==
                    category['id'].toString(),
              )
              .length,
      },
      auditTraceAsync: auditTraceAsync,
      scrollable: scrollable,
      onSelect: menuNotifier.selectCategory,
      onMove: (fromIndex, toIndex) {
        final reordered = [...categories];
        final category = reordered.removeAt(fromIndex);
        reordered.insert(toIndex, category);
        menuNotifier.reorderCategories(reordered);
      },
      onEdit: (category) =>
          _showEditCategoryDialog(context, category, menuNotifier),
      onDelete: (category, itemCount) =>
          _showDeleteCategoryDialog(context, category, itemCount, menuNotifier),
    );

    Widget itemsPane({required bool scrollable}) => _ItemsPanel(
      selectedItems: selectedItems,
      selectedCategoryId: selectedCategoryId,
      numberFormat: numberFormat,
      scrollable: scrollable,
      onToggleAvailability: menuNotifier.toggleAvailability,
      onTogglePublicVisibility: menuNotifier.togglePublicVisibility,
      onEditItem: (item) =>
          _showEditItemDialog(context, item, allItems, menuNotifier),
    );

    return Scaffold(
      key: const Key('admin_menu_root'),
      backgroundColor: AppColors.surface0,
      body: LayoutBuilder(
        builder: (context, viewport) {
          if (viewport.maxWidth < 960) {
            return ToastResponsiveScrollBody(
              maxWidth: 1420,
              padding: const EdgeInsets.all(16),
              children: [
                header,
                const SizedBox(height: 16),
                categoryPane(scrollable: false),
                const SizedBox(height: 16),
                itemsPane(scrollable: false),
              ],
            );
          }

          return ToastResponsiveBody(
            maxWidth: 1420,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 16),
                Expanded(
                  child: ToastSplitPane(
                    queueWidth: 360,
                    queue: categoryPane(scrollable: true),
                    detail: itemsPane(scrollable: true),
                    divider: false,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMenuCommandHeader({
    required int categoryCount,
    required int itemCount,
    required int availableItems,
    required int selectedItemCount,
    required String? selectedCategoryName,
    required VoidCallback? onExportExcel,
    required VoidCallback? onImportExcel,
    required ValueChanged<List<XFile>>? onImportFilesDropped,
    required VoidCallback onAddCategory,
    required VoidCallback? onAddItem,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.menuManagementTitle,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.menuManagementSubtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              );
              final actions = Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: constraints.maxWidth < 720
                    ? WrapAlignment.start
                    : WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    key: const Key('admin_menu_export_excel_action'),
                    onPressed: onExportExcel,
                    icon: _isExporting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 18),
                    label: Text(
                      _isExporting
                          ? context.l10n.menuExportInProgress
                          : context.l10n.menuExportExcel,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('admin_menu_import_excel_action'),
                    onPressed: onImportExcel,
                    icon: _isImporting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file_outlined, size: 18),
                    label: Text(
                      _isImporting
                          ? context.l10n.menuImportInProgress
                          : context.l10n.menuImportExcel,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('admin_menu_add_category_action'),
                    onPressed: onAddCategory,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: Text(context.l10n.menuAddCategory),
                  ),
                  FilledButton.icon(
                    key: const Key('admin_menu_add_item_action'),
                    onPressed: onAddItem,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(context.l10n.menuAddMenu),
                  ),
                ],
              );
              if (constraints.maxWidth < 720 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.5) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [titleBlock, const SizedBox(height: 12), actions],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: titleBlock),
                  const SizedBox(width: 12),
                  Flexible(child: actions),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          _MenuImportDropZone(
            enabled: !_isImportFlowActive && !_isExporting,
            onBrowse: onImportExcel,
            onFilesDropped: onImportFilesDropped,
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: context.l10n.menuCategoriesMetric,
                value: '$categoryCount',
              ),
              ToastMetric(
                label: context.l10n.menuItemsMetric,
                value: '$itemCount',
              ),
              ToastMetric(
                label: context.l10n.menuAvailableItemsMetric,
                value: '$availableItems',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: context.l10n.menuSelectedCategoryMetric,
                value: '$selectedItemCount',
                tone: selectedCategoryName == null
                    ? PosColors.textSecondary
                    : PosColors.accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ToastStatusBadge(
                label: context.l10n.menuConfiguration,
                color: PosColors.accent,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  selectedCategoryName == null
                      ? context.l10n.menuSelectCategoryEditHint
                      : context.l10n.menuEditingCategory(selectedCategoryName),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String? _categoryNameForId(
    List<Map<String, dynamic>> categories,
    String? categoryId,
  ) {
    if (categoryId == null) {
      return null;
    }

    for (final category in categories) {
      if (category['id']?.toString() == categoryId) {
        return category['name']?.toString() ?? '-';
      }
    }

    return null;
  }

  Future<void> _exportMenuWorkbook(
    String storeId,
    List<Map<String, dynamic>> categories,
    List<Map<String, dynamic>> items,
  ) async {
    setState(() => _isExporting = true);
    try {
      final bytes = Uint8List.fromList(
        buildMenuRoundTripWorkbook(
          storeId: storeId,
          categories: categories,
          items: items,
        ),
      );
      final now = DateTime.now();
      final stamp =
          '${now.year.toString().padLeft(4, '0')}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final fileName = 'menu_multilingual_$stamp';
      final saver = widget.saveExportFile;
      if (saver != null) {
        await saver('$fileName.xlsx', bytes);
      } else {
        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: bytes,
          ext: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
      if (mounted) {
        showSuccessToast(
          context,
          context.l10n.menuExportSuccess(categories.length, items.length),
        );
      }
    } catch (_) {
      if (mounted) showErrorToast(context, context.l10n.menuExportFailed);
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _importMenuWorkbook(
    String storeId,
    MenuNotifier menuNotifier,
  ) async {
    const typeGroup = XTypeGroup(
      label: 'Excel (.xlsx)',
      extensions: <String>['xlsx'],
    );

    final file =
        await (widget.pickImportFile?.call() ??
            openFile(acceptedTypeGroups: const <XTypeGroup>[typeGroup]));
    if (file != null && mounted) {
      await _processMenuWorkbook(file, storeId, menuNotifier);
    }
  }

  Future<void> _importDroppedMenuWorkbook(
    List<XFile> files,
    String storeId,
    MenuNotifier menuNotifier,
  ) async {
    if (files.length != 1) {
      await _showMenuImportValidationErrors(context, [
        context.l10n.menuImportDropSingleFile,
      ]);
      return;
    }
    final file = files.single;
    if (!file.name.toLowerCase().endsWith('.xlsx') &&
        !file.path.toLowerCase().endsWith('.xlsx')) {
      await _showMenuImportValidationErrors(context, [
        context.l10n.menuImportDropXlsxOnly,
      ]);
      return;
    }
    await _processMenuWorkbook(file, storeId, menuNotifier);
  }

  Future<void> _processMenuWorkbook(
    XFile file,
    String storeId,
    MenuNotifier menuNotifier,
  ) async {
    if (_isImportFlowActive) return;
    setState(() => _isImportFlowActive = true);

    try {
      final bytes = await file.readAsBytes();
      final roundTripWorkbook = tryParseMenuRoundTripWorkbook(bytes);
      if (!mounted) {
        return;
      }

      if (roundTripWorkbook != null) {
        if (roundTripWorkbook.storeIds.length != 1 ||
            roundTripWorkbook.storeIds.single != storeId) {
          throw const MenuImportValidationException([
            '현재 매장에서 내보낸 Excel 파일만 다시 가져올 수 있습니다.',
          ]);
        }
        final confirmed = await _showMenuImportPreview(
          context,
          storeLabel: storeId,
          categoryCount: roundTripWorkbook.categoryCount,
          itemCount: roundTripWorkbook.itemCount,
          isUpdate: true,
        );
        if (confirmed != true || !mounted) return;

        setState(() => _isImporting = true);
        final result = await menuNotifier.updateMenuWorkbook(
          categories: roundTripWorkbook.categories
              .map((row) => row.toJson())
              .toList(growable: false),
          items: roundTripWorkbook.items
              .map((row) => row.toJson())
              .toList(growable: false),
        );
        if (!mounted) return;

        if (result != null) {
          ref.invalidate(adminAuditTraceProvider(storeId));
          showSuccessToast(
            context,
            context.l10n.menuUpdateSuccess(
              result.updatedCategoryCount,
              result.updatedItemCount,
            ),
          );
        }
        return;
      }

      final workbook = parseMenuImportWorkbook(bytes);

      final confirmed = await _showMenuImportPreview(
        context,
        storeLabel: workbook.storeCodes.single,
        categoryCount: workbook.categoryCount,
        itemCount: workbook.itemCount,
      );
      if (confirmed != true || !mounted) {
        return;
      }

      setState(() => _isImporting = true);
      final result = await menuNotifier.importMenuItems(
        workbook.rows.map((row) => row.toJson()).toList(growable: false),
      );
      if (!mounted) {
        return;
      }

      if (result != null) {
        ref.invalidate(adminAuditTraceProvider(storeId));
        showSuccessToast(
          context,
          context.l10n.menuImportSuccess(
            result.categoryCount,
            result.itemCount,
          ),
        );
      }
    } on MenuImportValidationException catch (error) {
      if (mounted) {
        await _showMenuImportValidationErrors(context, error.issues);
      }
    } catch (_) {
      if (mounted) {
        showErrorToast(context, context.l10n.menuImportUnknownError);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isImportFlowActive = false;
          _isImporting = false;
        });
      }
    }
  }

  Future<bool?> _showMenuImportPreview(
    BuildContext context, {
    required String storeLabel,
    required int categoryCount,
    required int itemCount,
    bool isUpdate = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('admin_menu_import_preview_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(
          isUpdate
              ? context.l10n.menuUpdatePreviewTitle
              : context.l10n.menuImportPreviewTitle,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUpdate
                    ? context.l10n.menuUpdatePreviewBody(
                        categoryCount,
                        itemCount,
                      )
                    : context.l10n.menuImportPreviewBody(
                        storeLabel,
                        categoryCount,
                        itemCount,
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                isUpdate
                    ? context.l10n.menuUpdateAtomicHint
                    : context.l10n.menuImportAtomicHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.upload_file_outlined),
            label: Text(
              isUpdate
                  ? context.l10n.menuUpdateConfirm
                  : context.l10n.menuImportConfirm,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMenuImportValidationErrors(
    BuildContext context,
    List<String> issues,
  ) {
    final visibleIssues = issues.take(12).toList();
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('admin_menu_import_validation_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(context.l10n.menuImportValidationTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 420),
          child: SingleChildScrollView(
            child: Text(
              [
                ...visibleIssues.map((issue) => '• $issue'),
                if (issues.length > visibleIssues.length) '• …',
              ].join('\n'),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddCategoryDialog(
    BuildContext context,
    MenuNotifier menuNotifier,
  ) async {
    final l10n = context.l10n;
    final nameKoController = TextEditingController();
    final nameViController = TextEditingController();
    final nameEnController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          key: const Key('admin_menu_add_category_dialog'),
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.menuAddCategory,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('admin_menu_category_name_ko'),
                controller: nameKoController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuNameKorean),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_menu_category_name_vi'),
                controller: nameViController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuNameVietnamese),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_menu_category_name_en'),
                controller: nameEnController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuNameEnglish),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final nameKo = nameKoController.text.trim();
                final nameVi = nameViController.text.trim();
                final nameEn = nameEnController.text.trim();
                if (nameKo.isEmpty || nameVi.isEmpty || nameEn.isEmpty) {
                  showErrorToast(context, l10n.menuEnterCategoryName);
                  return;
                }

                final success = await menuNotifier.addCategory(
                  nameKo: nameKo,
                  nameVi: nameVi,
                  nameEn: nameEn,
                );
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, l10n.menuCategoryAdded(nameKo));
                  }
                }
              },
              child: Text(l10n.add),
            ),
          ],
        );
      },
    );

    await Future<void>.delayed(kThemeAnimationDuration);

    nameKoController.dispose();
    nameViController.dispose();
    nameEnController.dispose();
  }

  Future<void> _showEditCategoryDialog(
    BuildContext context,
    Map<String, dynamic> category,
    MenuNotifier menuNotifier,
  ) async {
    final l10n = context.l10n;
    final categoryId = category['id']?.toString() ?? '';
    final originalNameKo =
        category['name_ko']?.toString() ?? category['name']?.toString() ?? '';
    final originalNameVi = category['name_vi']?.toString() ?? originalNameKo;
    final originalNameEn = category['name_en']?.toString() ?? originalNameKo;
    if (categoryId.isEmpty) return;
    final nameKoController = TextEditingController(text: originalNameKo);
    final nameViController = TextEditingController(text: originalNameVi);
    final nameEnController = TextEditingController(text: originalNameEn);

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('admin_menu_edit_category_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(l10n.menuEditCategory),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('admin_menu_edit_category_name'),
              controller: nameKoController,
              autofocus: true,
              style: AppFonts.system(color: AppColors.textPrimary),
              decoration: InputDecoration(labelText: l10n.menuNameKorean),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameViController,
              style: AppFonts.system(color: AppColors.textPrimary),
              decoration: InputDecoration(labelText: l10n.menuNameVietnamese),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameEnController,
              style: AppFonts.system(color: AppColors.textPrimary),
              decoration: InputDecoration(labelText: l10n.menuNameEnglish),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final nameKo = nameKoController.text.trim();
              final nameVi = nameViController.text.trim();
              final nameEn = nameEnController.text.trim();
              if (nameKo.isEmpty || nameVi.isEmpty || nameEn.isEmpty) {
                showErrorToast(context, l10n.menuEnterCategoryName);
                return;
              }
              if (nameKo == originalNameKo &&
                  nameVi == originalNameVi &&
                  nameEn == originalNameEn) {
                showErrorToast(context, l10n.noChanges);
                return;
              }
              final success = await menuNotifier.updateCategory(
                categoryId: categoryId,
                nameKo: nameKo,
                nameVi: nameVi,
                nameEn: nameEn,
              );
              if (!context.mounted || !success) return;
              Navigator.of(context).pop();
              showSuccessToast(context, l10n.menuCategorySaved(nameKo));
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );

    await Future<void>.delayed(kThemeAnimationDuration);
    nameKoController.dispose();
    nameViController.dispose();
    nameEnController.dispose();
  }

  Future<void> _showDeleteCategoryDialog(
    BuildContext context,
    Map<String, dynamic> category,
    int itemCount,
    MenuNotifier menuNotifier,
  ) async {
    final l10n = context.l10n;
    final categoryId = category['id']?.toString() ?? '';
    final name = category['name']?.toString() ?? '-';
    if (categoryId.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('admin_menu_delete_category_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(l10n.menuDeleteCategoryTitle),
        content: Text(
          itemCount > 0
              ? l10n.menuCategoryDeleteBlocked(itemCount)
              : l10n.menuDeleteCategoryConfirm(name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(itemCount > 0 ? l10n.confirm : l10n.cancel),
          ),
          if (itemCount == 0)
            FilledButton(
              key: const Key('admin_menu_delete_category_confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.statusCancelled,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final success = await menuNotifier.deleteCategory(categoryId);
                if (!context.mounted || !success) return;
                Navigator.of(context).pop();
                showSuccessToast(context, l10n.menuCategoryDeleted(name));
              },
              child: Text(l10n.menuDelete),
            ),
        ],
      ),
    );
  }

  Future<void> _showAddItemDialog(
    BuildContext context,
    String? categoryId,
    List<Map<String, dynamic>> allItems,
    MenuNotifier menuNotifier,
  ) async {
    if (categoryId == null) {
      return;
    }

    final l10n = context.l10n;
    final nameKoController = TextEditingController();
    final nameViController = TextEditingController();
    final nameEnController = TextEditingController();
    final priceController = TextEditingController();
    XFile? selectedPhoto;
    Uint8List? selectedPreviewBytes;
    var isCombo = false;
    final comboQuantities = <String, int>{};
    var comboDrinkChoiceCount = 0;
    final comboCandidates = allItems
        .where((candidate) => candidate['is_combo'] != true)
        .toList(growable: false);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            key: const Key('admin_menu_add_item_dialog'),
            backgroundColor: AppColors.surface1,
            title: Text(
              l10n.menuAddMenu,
              style: AppFonts.system(color: AppColors.textPrimary),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('admin_menu_item_name_ko'),
                    controller: nameKoController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: l10n.menuNameKorean),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('admin_menu_item_name_vi'),
                    controller: nameViController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.menuNameVietnamese,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('admin_menu_item_name_en'),
                    controller: nameEnController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.menuNameEnglish,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: priceController,
                    keyboardType: TextInputType.number,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: l10n.menuPrice),
                  ),
                  const SizedBox(height: 16),
                  _ComboMenuEditor(
                    isCombo: isCombo,
                    candidates: comboCandidates,
                    quantities: comboQuantities,
                    drinkChoiceCount: comboDrinkChoiceCount,
                    onComboChanged: (value) => setDialogState(() {
                      isCombo = value;
                      if (!value) {
                        comboQuantities.clear();
                        comboDrinkChoiceCount = 0;
                      }
                    }),
                    onQuantityChanged: (itemId, quantity) => setDialogState(() {
                      if (quantity == null) {
                        comboQuantities.remove(itemId);
                      } else {
                        comboQuantities[itemId] = quantity;
                      }
                    }),
                    onDrinkChoiceCountChanged: (value) =>
                        setDialogState(() => comboDrinkChoiceCount = value),
                  ),
                  const SizedBox(height: 16),
                  _MenuPhotoPicker(
                    previewBytes: selectedPreviewBytes,
                    imageUrl: null,
                    onChoose: () async {
                      final photo = await _imagePicker.pickImage(
                        source: ImageSource.gallery,
                      );
                      if (photo == null) return;
                      final bytes = await photo.readAsBytes();
                      setDialogState(() {
                        selectedPhoto = photo;
                        selectedPreviewBytes = bytes;
                      });
                    },
                    onRemove: selectedPhoto == null
                        ? null
                        : () => setDialogState(() {
                            selectedPhoto = null;
                            selectedPreviewBytes = null;
                          }),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                onPressed: () async {
                  final nameKo = nameKoController.text.trim();
                  final nameVi = nameViController.text.trim();
                  final nameEn = nameEnController.text.trim();
                  final price = parseDecimalInput(priceController.text);
                  if (nameKo.isEmpty ||
                      nameVi.isEmpty ||
                      nameEn.isEmpty ||
                      price == null ||
                      price <= 0) {
                    showErrorToast(context, l10n.menuEnterValidNameAndPrice);
                    return;
                  }
                  if (isCombo && comboQuantities.isEmpty) {
                    showErrorToast(context, l10n.menuComboComponentRequired);
                    return;
                  }
                  final photo = selectedPhoto;
                  final comboComponents = _comboPayload(comboQuantities);
                  final success = photo == null
                      ? await menuNotifier.addMenuItem(
                          categoryId: categoryId,
                          nameKo: nameKo,
                          nameVi: nameVi,
                          nameEn: nameEn,
                          price: price,
                          isCombo: isCombo,
                          comboComponents: comboComponents,
                          comboDrinkChoiceCount: comboDrinkChoiceCount,
                        )
                      : await menuNotifier.addMenuItemWithPhoto(
                          categoryId: categoryId,
                          nameKo: nameKo,
                          nameVi: nameVi,
                          nameEn: nameEn,
                          price: price,
                          photo: photo,
                          isCombo: isCombo,
                          comboComponents: comboComponents,
                          comboDrinkChoiceCount: comboDrinkChoiceCount,
                        );
                  if (context.mounted && success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, l10n.menuAdded(nameKo));
                  }
                },
                child: Text(l10n.add),
              ),
            ],
          ),
        );
      },
    );

    await Future<void>.delayed(kThemeAnimationDuration);

    nameKoController.dispose();
    nameViController.dispose();
    nameEnController.dispose();
    priceController.dispose();
  }

  Future<void> _showEditItemDialog(
    BuildContext context,
    Map<String, dynamic> item,
    List<Map<String, dynamic>> allItems,
    MenuNotifier menuNotifier,
  ) async {
    final l10n = context.l10n;
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) {
      return;
    }
    final originalNameKo =
        item['name_ko']?.toString() ?? item['name']?.toString() ?? '';
    final originalNameVi = item['name_vi']?.toString() ?? originalNameKo;
    final originalNameEn = item['name_en']?.toString() ?? originalNameKo;
    final nameKoController = TextEditingController(text: originalNameKo);
    final nameViController = TextEditingController(text: originalNameVi);
    final nameEnController = TextEditingController(text: originalNameEn);
    final rawPrice = item['price'];
    final initialPrice = switch (rawPrice) {
      num value => value.toDouble(),
      String value => parseDecimalInput(value) ?? 0,
      _ => 0.0,
    };
    final priceController = TextEditingController(
      text: initialPrice <= 0 ? '' : initialPrice.toStringAsFixed(0),
    );
    final existingImageUrl = item['image_url']?.toString();
    final existingStoragePath = item['image_storage_path']?.toString();
    XFile? selectedPhoto;
    Uint8List? selectedPreviewBytes;
    var removeExistingPhoto = false;
    final originalIsCombo = item['is_combo'] == true;
    var isCombo = originalIsCombo;
    final originalFloorDirect = item['fulfillment_route'] == 'floor_direct';
    var floorDirect = originalFloorDirect;
    final originalComboQuantities = _comboQuantitiesFromItem(item);
    final comboQuantities = Map<String, int>.from(originalComboQuantities);
    final originalComboDrinkChoiceCount =
        switch (item['combo_drink_choice_count']) {
          int value => value,
          num value => value.toInt(),
          String value => int.tryParse(value) ?? 0,
          _ => 0,
        };
    var comboDrinkChoiceCount = originalComboDrinkChoiceCount;
    final comboCandidates = allItems
        .where(
          (candidate) =>
              candidate['id']?.toString() != itemId &&
              candidate['is_combo'] != true,
        )
        .toList(growable: false);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            key: const Key('admin_menu_edit_item_dialog'),
            backgroundColor: AppColors.surface1,
            title: Text(
              l10n.menuEditMenu,
              style: AppFonts.system(color: AppColors.textPrimary),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameKoController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: l10n.menuNameKorean),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameViController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.menuNameVietnamese,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameEnController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.menuNameEnglish,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: priceController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: l10n.menuPrice),
                  ),
                  const SizedBox(height: 16),
                  _ComboMenuEditor(
                    isCombo: isCombo,
                    candidates: comboCandidates,
                    quantities: comboQuantities,
                    drinkChoiceCount: comboDrinkChoiceCount,
                    onComboChanged: (value) => setDialogState(() {
                      isCombo = value;
                      if (value) floorDirect = false;
                      if (!value) {
                        comboQuantities.clear();
                        comboDrinkChoiceCount = 0;
                      }
                    }),
                    onQuantityChanged: (componentId, quantity) =>
                        setDialogState(() {
                          if (quantity == null) {
                            comboQuantities.remove(componentId);
                          } else {
                            comboQuantities[componentId] = quantity;
                          }
                        }),
                    onDrinkChoiceCountChanged: (value) =>
                        setDialogState(() => comboDrinkChoiceCount = value),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    key: const Key('admin_menu_floor_direct'),
                    contentPadding: EdgeInsets.zero,
                    value: floorDirect,
                    onChanged: isCombo
                        ? null
                        : (value) => setDialogState(() => floorDirect = value),
                    secondary: const Icon(Icons.local_drink_outlined),
                    title: Text(switch (Localizations.localeOf(
                      context,
                    ).languageCode) {
                      'vi' => 'Phục vụ trực tiếp tại tầng',
                      'en' => 'Serve directly by floor',
                      _ => '층에서 직접 제공',
                    }),
                    subtitle: Text(switch (Localizations.localeOf(
                      context,
                    ).languageCode) {
                      'vi' =>
                        'Bếp và khay chỉ hiển thị; tầng chịu trách nhiệm hoàn tất.',
                      'en' =>
                        'Kitchen and tray are read-only; the floor completes it.',
                      _ => '주방·트레이에서는 확인만 하고 담당 층에서 완료합니다.',
                    }),
                  ),
                  const SizedBox(height: 16),
                  _MenuPhotoPicker(
                    previewBytes: selectedPreviewBytes,
                    imageUrl: removeExistingPhoto ? null : existingImageUrl,
                    onChoose: () async {
                      final photo = await _imagePicker.pickImage(
                        source: ImageSource.gallery,
                      );
                      if (photo == null) return;
                      final bytes = await photo.readAsBytes();
                      setDialogState(() {
                        selectedPhoto = photo;
                        selectedPreviewBytes = bytes;
                        removeExistingPhoto = false;
                      });
                    },
                    onRemove:
                        selectedPhoto != null ||
                            (!removeExistingPhoto &&
                                existingImageUrl != null &&
                                existingImageUrl.isNotEmpty)
                        ? () => setDialogState(() {
                            selectedPhoto = null;
                            selectedPreviewBytes = null;
                            removeExistingPhoto =
                                existingImageUrl != null &&
                                existingImageUrl.isNotEmpty;
                          })
                        : null,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                onPressed: () async {
                  final nameKo = nameKoController.text.trim();
                  final nameVi = nameViController.text.trim();
                  final nameEn = nameEnController.text.trim();
                  final price = parseDecimalInput(priceController.text);
                  if (nameKo.isEmpty ||
                      nameVi.isEmpty ||
                      nameEn.isEmpty ||
                      price == null ||
                      price <= 0) {
                    showErrorToast(context, l10n.menuEnterValidNameAndPrice);
                    return;
                  }
                  if (isCombo && comboQuantities.isEmpty) {
                    showErrorToast(context, l10n.menuComboComponentRequired);
                    return;
                  }
                  final detailsChanged =
                      nameKo != originalNameKo ||
                      nameVi != originalNameVi ||
                      nameEn != originalNameEn ||
                      price != initialPrice;
                  final photoChanged =
                      selectedPhoto != null || removeExistingPhoto;
                  final comboChanged =
                      isCombo != originalIsCombo ||
                      comboDrinkChoiceCount != originalComboDrinkChoiceCount ||
                      !_sameComboQuantities(
                        comboQuantities,
                        originalComboQuantities,
                      );
                  final routeChanged = floorDirect != originalFloorDirect;
                  if (!detailsChanged &&
                      !photoChanged &&
                      !comboChanged &&
                      !routeChanged) {
                    showErrorToast(context, l10n.noChanges);
                    return;
                  }

                  if (detailsChanged) {
                    final detailsSaved = await menuNotifier.updateMenuItem(
                      itemId: itemId,
                      nameKo: nameKo,
                      nameVi: nameVi,
                      nameEn: nameEn,
                      price: price,
                    );
                    if (!detailsSaved) return;
                  }

                  if (comboChanged) {
                    final comboSaved = await menuNotifier.setMenuCombo(
                      itemId: itemId,
                      isCombo: isCombo,
                      components: _comboPayload(comboQuantities),
                      drinkChoiceCount: comboDrinkChoiceCount,
                    );
                    if (!comboSaved) return;
                  }

                  if (routeChanged) {
                    final routeSaved = await menuNotifier
                        .setMenuFulfillmentRoute(
                          itemId: itemId,
                          floorDirect: floorDirect,
                        );
                    if (!routeSaved) return;
                  }

                  final photo = selectedPhoto;
                  if (photo != null) {
                    final photoSaved = await menuNotifier.replaceMenuItemImage(
                      itemId: itemId,
                      photo: photo,
                      previousStoragePath: existingStoragePath,
                    );
                    if (!photoSaved) return;
                  } else if (removeExistingPhoto) {
                    final photoRemoved = await menuNotifier.removeMenuItemImage(
                      itemId: itemId,
                      storagePath: existingStoragePath,
                    );
                    if (!photoRemoved) return;
                  }

                  if (context.mounted) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, l10n.menuSaved(nameKo));
                  }
                },
                child: Text(l10n.save),
              ),
            ],
          ),
        );
      },
    );

    await Future<void>.delayed(kThemeAnimationDuration);

    nameKoController.dispose();
    nameViController.dispose();
    nameEnController.dispose();
    priceController.dispose();
  }
}

Map<String, int> _comboQuantitiesFromItem(Map<String, dynamic> item) {
  final rawComponents = item['menu_combo_components'];
  if (rawComponents is! List) return {};

  return {
    for (final raw in rawComponents.whereType<Map>())
      if ((raw['component_menu_item_id']?.toString() ?? '').isNotEmpty)
        raw['component_menu_item_id'].toString(): switch (raw['quantity']) {
          int value => value,
          num value => value.toInt(),
          String value => int.tryParse(value) ?? 1,
          _ => 1,
        },
  };
}

List<Map<String, dynamic>> _comboPayload(Map<String, int> quantities) {
  return quantities.entries
      .map((entry) => {'menu_item_id': entry.key, 'quantity': entry.value})
      .toList(growable: false);
}

bool _sameComboQuantities(Map<String, int> left, Map<String, int> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

class _ComboMenuEditor extends StatelessWidget {
  const _ComboMenuEditor({
    required this.isCombo,
    required this.candidates,
    required this.quantities,
    required this.drinkChoiceCount,
    required this.onComboChanged,
    required this.onQuantityChanged,
    required this.onDrinkChoiceCountChanged,
  });

  final bool isCombo;
  final List<Map<String, dynamic>> candidates;
  final Map<String, int> quantities;
  final int drinkChoiceCount;
  final ValueChanged<bool> onComboChanged;
  final void Function(String itemId, int? quantity) onQuantityChanged;
  final ValueChanged<int> onDrinkChoiceCountChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      key: const Key('admin_menu_combo_editor'),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const Key('admin_menu_combo_toggle'),
            value: isCombo,
            onChanged: onComboChanged,
            title: Text(l10n.menuComboToggle),
            subtitle: Text(l10n.menuComboDescription),
            activeThumbColor: AppColors.amber500,
          ),
          if (isCombo) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                l10n.menuComboComponents,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                child: Text(
                  l10n.menuComboNoCandidates,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Column(
                    children: [
                      for (final (index, candidate) in candidates.indexed) ...[
                        _ComboCandidateRow(
                          candidate: candidate,
                          quantity:
                              quantities[candidate['id']?.toString() ?? ''],
                          onQuantityChanged: onQuantityChanged,
                        ),
                        if (index != candidates.length - 1)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: DropdownButtonFormField<int>(
                key: const Key('admin_menu_combo_drink_count'),
                initialValue: drinkChoiceCount,
                decoration: InputDecoration(
                  labelText: l10n.menuComboDrinkChoiceSlot,
                  helperText: l10n.menuComboDrinkChoiceSlotHelp,
                ),
                items: [
                  for (var count = 0; count <= 10; count++)
                    DropdownMenuItem<int>(value: count, child: Text('$count')),
                ],
                onChanged: (value) => onDrinkChoiceCountChanged(value ?? 0),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ComboCandidateRow extends StatelessWidget {
  const _ComboCandidateRow({
    required this.candidate,
    required this.quantity,
    required this.onQuantityChanged,
  });

  final Map<String, dynamic> candidate;
  final int? quantity;
  final void Function(String itemId, int? quantity) onQuantityChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final itemId = candidate['id']?.toString() ?? '';
    final selected = quantity != null;
    final currentQuantity = quantity ?? 1;
    return CheckboxListTile(
      key: Key('admin_menu_combo_component_$itemId'),
      value: selected,
      onChanged: itemId.isEmpty
          ? null
          : (value) => onQuantityChanged(
              itemId,
              value == true ? currentQuantity : null,
            ),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        candidate['name']?.toString() ?? '-',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: candidate['is_available'] == false
          ? Text(l10n.menuSoldOut)
          : null,
      secondary: selected
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('admin_menu_combo_decrease_$itemId'),
                  tooltip: l10n.menuComboDecreaseQuantity,
                  onPressed: currentQuantity <= 1
                      ? null
                      : () => onQuantityChanged(itemId, currentQuantity - 1),
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                ),
                Text(
                  '$currentQuantity',
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  key: Key('admin_menu_combo_increase_$itemId'),
                  tooltip: l10n.menuComboIncreaseQuantity,
                  onPressed: currentQuantity >= 99
                      ? null
                      : () => onQuantityChanged(itemId, currentQuantity + 1),
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                ),
              ],
            )
          : null,
    );
  }
}

class _MenuImportDropZone extends StatefulWidget {
  const _MenuImportDropZone({
    required this.enabled,
    required this.onBrowse,
    required this.onFilesDropped,
  });

  final bool enabled;
  final VoidCallback? onBrowse;
  final ValueChanged<List<XFile>>? onFilesDropped;

  @override
  State<_MenuImportDropZone> createState() => _MenuImportDropZoneState();
}

class _MenuImportDropZoneState extends State<_MenuImportDropZone> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onFilesDropped != null;
    final borderColor = _isDragging ? AppColors.amber500 : AppColors.surface3;

    return DropTarget(
      enable: active,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);
        widget.onFilesDropped?.call(
          details.files.map<XFile>((file) => file).toList(growable: false),
        );
      },
      child: Material(
        key: const Key('admin_menu_import_drop_zone'),
        color: _isDragging
            ? AppColors.amber500.withValues(alpha: 0.08)
            : AppColors.surface0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor, width: _isDragging ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onBrowse,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  _isDragging
                      ? Icons.file_download_done_outlined
                      : Icons.file_download_outlined,
                  color: active ? AppColors.amber500 : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isDragging
                            ? context.l10n.menuImportDropRelease
                            : context.l10n.menuImportDropTitle,
                        style: AppFonts.system(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        context.l10n.menuImportDropHint,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  key: const Key('admin_menu_import_browse_action'),
                  onPressed: widget.onBrowse,
                  child: Text(context.l10n.menuImportBrowse),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuPhotoPicker extends StatelessWidget {
  const _MenuPhotoPicker({
    required this.previewBytes,
    required this.imageUrl,
    required this.onChoose,
    required this.onRemove,
  });

  final Uint8List? previewBytes;
  final String? imageUrl;
  final VoidCallback onChoose;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final hasNetworkImage = imageUrl != null && imageUrl!.trim().isNotEmpty;
    final hasImage = previewBytes != null || hasNetworkImage;

    Widget preview;
    if (previewBytes != null) {
      preview = Image.memory(previewBytes!, fit: BoxFit.cover);
    } else if (hasNetworkImage) {
      preview = Image.network(
        imageUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(
          Icons.broken_image_outlined,
          color: AppColors.textSecondary,
        ),
      );
    } else {
      preview = const Icon(
        Icons.restaurant_menu_outlined,
        color: AppColors.textSecondary,
        size: 32,
      );
    }

    return Container(
      key: const Key('admin_menu_photo_picker'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: AppColors.surface2,
              child: SizedBox(
                width: 88,
                height: 88,
                child: Center(child: preview),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.menuPhoto,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.l10n.menuPhotoHint,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('admin_menu_choose_photo'),
                      onPressed: onChoose,
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: Text(
                        hasImage
                            ? context.l10n.menuReplacePhoto
                            : context.l10n.menuChoosePhoto,
                      ),
                    ),
                    if (onRemove != null)
                      TextButton.icon(
                        key: const Key('admin_menu_remove_photo'),
                        onPressed: onRemove,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text(context.l10n.menuRemovePhoto),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryPanel extends StatelessWidget {
  const _CategoryPanel({
    required this.categories,
    required this.selectedCategoryId,
    required this.itemCountsByCategory,
    required this.auditTraceAsync,
    required this.onSelect,
    required this.onMove,
    required this.onEdit,
    required this.onDelete,
    this.scrollable = true,
  });

  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final Map<String, int> itemCountsByCategory;
  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final ValueChanged<String> onSelect;
  final void Function(int fromIndex, int toIndex) onMove;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final void Function(Map<String, dynamic> category, int itemCount) onDelete;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final categoryBody = categories.isEmpty
        ? PosEmptyState(
            title: l10n.menuNoCategories,
            subtitle: l10n.menuCreateRailFirst,
          )
        : ListView.separated(
            shrinkWrap: !scrollable,
            physics: scrollable ? null : const NeverScrollableScrollPhysics(),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final category = categories[index];
              final categoryId = category['id']?.toString() ?? '';
              final isSelected = categoryId == selectedCategoryId;
              final isSystemAlcohol = category['system_key'] == 'alcohol';

              return PosListRow(
                selected: isSelected,
                statusColor: AppColors.amber500,
                onTap: categoryId.isEmpty ? null : () => onSelect(categoryId),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category['name']?.toString() ?? '-',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.system(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                          if (isSystemAlcohol)
                            Text(
                              l10n.menuProtectedAlcoholCategory,
                              style: AppFonts.system(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (isSystemAlcohol)
                      Tooltip(
                        message: l10n.menuProtectedAlcoholCategory,
                        child: const Icon(
                          Icons.lock_outline,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    if (isSelected) ...[
                      IconButton(
                        key: Key('admin_menu_category_up_$categoryId'),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.menuMoveCategoryUp,
                        onPressed: index == 0
                            ? null
                            : () => onMove(index, index - 1),
                        icon: const Icon(Icons.arrow_upward, size: 18),
                      ),
                      IconButton(
                        key: Key('admin_menu_category_down_$categoryId'),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.menuMoveCategoryDown,
                        onPressed: index == categories.length - 1
                            ? null
                            : () => onMove(index, index + 1),
                        icon: const Icon(Icons.arrow_downward, size: 18),
                      ),
                    ],
                    if (isSelected && !isSystemAlcohol) ...[
                      IconButton(
                        key: Key('admin_menu_edit_category_$categoryId'),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.menuEditCategory,
                        onPressed: categoryId.isEmpty
                            ? null
                            : () => onEdit(category),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      IconButton(
                        key: Key('admin_menu_delete_category_$categoryId'),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.menuDeleteCategory,
                        onPressed: categoryId.isEmpty
                            ? null
                            : () => onDelete(
                                category,
                                itemCountsByCategory[categoryId] ?? 0,
                              ),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: AppColors.statusCancelled,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );

    return PosDataPanel(
      title: l10n.menuCategoriesMetric,
      subtitle: l10n.menuCategoryPanelSubtitle,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (scrollable) Expanded(child: categoryBody) else categoryBody,
          const SizedBox(height: 12),
          _MenuAuditDisclosure(auditTraceAsync: auditTraceAsync),
        ],
      ),
    );
  }
}

class _ItemsPanel extends StatelessWidget {
  const _ItemsPanel({
    required this.selectedItems,
    required this.selectedCategoryId,
    required this.numberFormat,
    required this.onToggleAvailability,
    required this.onTogglePublicVisibility,
    required this.onEditItem,
    this.scrollable = true,
  });

  final List<Map<String, dynamic>> selectedItems;
  final String? selectedCategoryId;
  final NumberFormat numberFormat;
  final Future<bool> Function(String itemId, bool isAvailable)
  onToggleAvailability;
  final Future<bool> Function(String itemId, bool isVisiblePublic)
  onTogglePublicVisibility;
  final ValueChanged<Map<String, dynamic>> onEditItem;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget panelBody(Widget child) =>
        scrollable ? Expanded(child: child) : child;

    return PosDataPanel(
      title: l10n.menuItemsPanelTitle,
      subtitle: selectedCategoryId == null
          ? l10n.menuItemsSelectCategorySubtitle
          : l10n.menuItemsReadySubtitle,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selectedCategoryId == null)
            panelBody(
              PosEmptyState(
                title: l10n.menuSelectCategoryTitle,
                subtitle: l10n.menuSelectCategoryMessage,
                icon: Icons.restaurant_menu_outlined,
              ),
            )
          else if (selectedItems.isEmpty)
            panelBody(
              PosEmptyState(
                title: l10n.menuNoItemsTitle,
                subtitle: l10n.menuNoItemsMessage,
                icon: Icons.fastfood_outlined,
              ),
            )
          else
            panelBody(
              ListView.separated(
                shrinkWrap: !scrollable,
                physics: scrollable
                    ? null
                    : const NeverScrollableScrollPhysics(),
                itemCount: selectedItems.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = selectedItems[index];
                  final itemId = item['id']?.toString() ?? '';
                  final name = item['name']?.toString() ?? '-';
                  final priceRaw = item['price'];
                  final isAvailable = item['is_available'] == true;
                  final isVisiblePublic = item['is_visible_public'] != false;
                  final imageUrl = item['image_url']?.toString();
                  final isCombo = item['is_combo'] == true;
                  final comboComponentsRaw = item['menu_combo_components'];
                  final comboComponents = comboComponentsRaw is List
                      ? comboComponentsRaw.whereType<Map>().toList()
                      : const <Map>[];
                  final priceValue = switch (priceRaw) {
                    num value => value.toDouble(),
                    _ => 0.0,
                  };

                  return Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface1,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.surface3),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final itemDetails = Row(
                          children: [
                            _MenuItemThumbnail(imageUrl: imageUrl),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppFonts.system(
                                      color: AppColors.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '₫${numberFormat.format(priceValue)}',
                                    style: AppFonts.system(
                                      color: AppColors.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (isCombo) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      comboComponents
                                          .map((component) {
                                            final componentItem =
                                                component['component'];
                                            final componentName =
                                                componentItem is Map
                                                ? componentItem['name']
                                                          ?.toString() ??
                                                      '-'
                                                : '-';
                                            final quantity =
                                                component['quantity']
                                                    ?.toString() ??
                                                '1';
                                            return '$componentName ×$quantity';
                                          })
                                          .join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppFonts.system(
                                        color: AppColors.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                    if ((item['combo_drink_choice_count']
                                                as num?)
                                            ?.toInt() !=
                                        0) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        '${l10n.menuComboDrinkChoiceSlot}: ${item['combo_drink_choice_count']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppFonts.system(
                                          color: AppColors.textSecondary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                        final itemActions = Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (isCombo)
                              ToastStatusBadge(
                                label: l10n.menuComboBadge,
                                color: PosColors.accent,
                                compact: true,
                              ),
                            ToastStatusBadge(
                              label: isAvailable
                                  ? l10n.menuAvailable
                                  : l10n.menuSoldOut,
                              color: isAvailable
                                  ? PosColors.success
                                  : PosColors.textSecondary,
                              compact: true,
                            ),
                            Tooltip(
                              message: 'Show on QR menu',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'QR',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Switch(
                                    key: Key('admin_menu_qr_public_$itemId'),
                                    value: isVisiblePublic,
                                    activeThumbColor: AppColors.amber500,
                                    onChanged: itemId.isEmpty
                                        ? null
                                        : (value) async {
                                            final success =
                                                await onTogglePublicVisibility(
                                                  itemId,
                                                  value,
                                                );
                                            if (!context.mounted || !success) {
                                              return;
                                            }
                                            showSuccessToast(
                                              context,
                                              value
                                                  ? '$name visible on QR menu'
                                                  : '$name hidden from QR menu',
                                            );
                                          },
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: isAvailable,
                              activeThumbColor: AppColors.amber500,
                              onChanged: itemId.isEmpty
                                  ? null
                                  : (value) async {
                                      final success =
                                          await onToggleAvailability(
                                            itemId,
                                            value,
                                          );
                                      if (!context.mounted || !success) return;
                                      showSuccessToast(
                                        context,
                                        value
                                            ? l10n.menuMarkedAvailable(name)
                                            : l10n.menuMarkedSoldOut(name),
                                      );
                                    },
                            ),
                            IconButton(
                              key: Key('admin_menu_edit_item_$itemId'),
                              onPressed: itemId.isEmpty
                                  ? null
                                  : () => onEditItem(item),
                              icon: const Icon(
                                Icons.edit_outlined,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: l10n.menuEditMenu,
                            ),
                          ],
                        );
                        if (constraints.maxWidth < 760) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              itemDetails,
                              const SizedBox(height: 10),
                              itemActions,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: itemDetails),
                            const SizedBox(width: 12),
                            itemActions,
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuItemThumbnail extends StatelessWidget {
  const _MenuItemThumbnail({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: AppColors.surface2,
        child: SizedBox(
          width: 54,
          height: 54,
          child: url.isEmpty
              ? const Icon(Icons.image_outlined, color: AppColors.textSecondary)
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: AppColors.textSecondary,
                  ),
                ),
        ),
      ),
    );
  }
}

class _MenuAuditDisclosure extends StatelessWidget {
  const _MenuAuditDisclosure({required this.auditTraceAsync});

  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('menu_audit_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          l10n.changeHistory,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.menuRecentChangesHint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(color: AppColors.textSecondary, fontSize: 11),
        ),
        children: [
          AdminAuditTracePanel(
            auditTraceAsync: auditTraceAsync,
            allowedEntityTypes: const {'menu_categories', 'menu_items'},
            maxItems: 3,
            compact: true,
            emptyMessage: l10n.menuNoRecentChanges,
          ),
        ],
      ),
    );
  }
}

class _RestaurantMissingView extends StatelessWidget {
  const _RestaurantMissingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          context.l10n.menuNoLinkedStoreMessage,
          style: AppFonts.system(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
