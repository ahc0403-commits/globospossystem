import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/error_toast.dart';
import 'qr_takeout_service.dart';

class QrTakeoutSettingsCard extends StatefulWidget {
  const QrTakeoutSettingsCard({super.key, required this.storeId, this.service});

  final String storeId;
  final QrTakeoutService? service;

  @override
  State<QrTakeoutSettingsCard> createState() => _QrTakeoutSettingsCardState();
}

class _QrTakeoutSettingsCardState extends State<QrTakeoutSettingsCard> {
  late Future<QrTakeoutAvailability> _future = _load();
  bool _isSaving = false;

  QrTakeoutService get _service => widget.service ?? qrTakeoutService;

  Future<QrTakeoutAvailability> _load() =>
      _service.getAvailability(widget.storeId);

  void _reload() => setState(() => _future = _load());

  Future<void> _setAvailability(bool enabled, {DateTime? resumeAt}) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final setting = await _service.setAvailability(
        storeId: widget.storeId,
        enabled: enabled,
        resumeAt: resumeAt,
      );
      if (!mounted) return;
      setState(() => _future = Future.value(setting));
      showSuccessToast(context, context.l10n.settingsQrTakeoutSaved);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          '${context.l10n.settingsQrTakeoutSaveFailed}: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _scheduleResume(QrTakeoutAvailability setting) async {
    final now = DateTime.now();
    var selected = setting.resumeAt?.isAfter(now) == true
        ? setting.resumeAt!
        : DateTime(now.year, now.month, now.day + 1);
    String? validationMessage;
    final resumeAt = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          key: const Key('settings_qr_takeout_resume_dialog'),
          title: Text(context.l10n.settingsQrTakeoutScheduleDialogTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('settings_qr_takeout_resume_date'),
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: selected,
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: DateTime(now.year + 10),
                          );
                          if (date == null) return;
                          setModalState(() {
                            selected = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              selected.hour,
                              selected.minute,
                            );
                            validationMessage = null;
                          });
                        },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          '${context.l10n.settingsQrTakeoutResumeDate}\n'
                          '${DateFormat('dd/MM/yyyy').format(selected)}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('settings_qr_takeout_resume_time'),
                        onPressed: () async {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(selected),
                          );
                          if (time == null) return;
                          setModalState(() {
                            selected = DateTime(
                              selected.year,
                              selected.month,
                              selected.day,
                              time.hour,
                              time.minute,
                            );
                            validationMessage = null;
                          });
                        },
                        icon: const Icon(Icons.schedule_outlined),
                        label: Text(
                          '${context.l10n.settingsQrTakeoutResumeTime}\n'
                          '${DateFormat('HH:mm').format(selected)}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
                if (validationMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    validationMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('settings_qr_takeout_resume_save'),
              onPressed: () {
                if (!selected.isAfter(DateTime.now())) {
                  setModalState(
                    () => validationMessage =
                        context.l10n.settingsQrTakeoutFutureRequired,
                  );
                  return;
                }
                Navigator.pop(dialogContext, selected);
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    if (resumeAt != null && mounted) {
      await _setAvailability(false, resumeAt: resumeAt);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings_qr_takeout_section'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.border),
      ),
      child: FutureBuilder<QrTakeoutAvailability>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Row(
              children: [
                Expanded(child: _title(context)),
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            );
          }
          final setting = snapshot.data;
          if (setting == null) {
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _title(context),
                      const SizedBox(height: 8),
                      Text(context.l10n.settingsQrTakeoutSaveFailed),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('settings_qr_takeout_retry'),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh_outlined),
                ),
              ],
            );
          }
          final resumeLabel = setting.resumeAt == null
              ? context.l10n.settingsQrTakeoutNoAutoResume
              : context.l10n.settingsQrTakeoutResumeAt(
                  DateFormat('dd/MM/yyyy HH:mm').format(setting.resumeAt!),
                );
          return Column(
            key: const Key('settings_qr_takeout_control'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                key: const Key('settings_qr_takeout_toggle'),
                contentPadding: EdgeInsets.zero,
                value: setting.effectiveEnabled,
                onChanged: _isSaving
                    ? null
                    : (enabled) => _setAvailability(enabled),
                title: Text(context.l10n.settingsQrTakeoutTitle),
                subtitle: Text(context.l10n.settingsQrTakeoutSummary),
                secondary: _isSaving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        setting.effectiveEnabled
                            ? Icons.takeout_dining_outlined
                            : Icons.hide_source_outlined,
                      ),
              ),
              Row(
                children: [
                  ToastStatusBadge(
                    key: const Key('settings_qr_takeout_status'),
                    label: setting.effectiveEnabled
                        ? context.l10n.settingsQrTakeoutEnabled
                        : context.l10n.settingsQrTakeoutDisabled,
                    color: setting.effectiveEnabled
                        ? PosColors.success
                        : PosColors.warning,
                    compact: true,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      setting.effectiveEnabled ? '' : resumeLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (!setting.effectiveEnabled) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('settings_qr_takeout_schedule_resume'),
                    onPressed: _isSaving
                        ? null
                        : () => _scheduleResume(setting),
                    icon: const Icon(Icons.event_repeat_outlined),
                    label: Text(context.l10n.settingsQrTakeoutScheduleResume),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _title(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.settingsQrTakeoutTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          context.l10n.settingsQrTakeoutSummary,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
