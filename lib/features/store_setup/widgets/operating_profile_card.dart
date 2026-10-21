import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/utils/floor_label.dart';
import '../store_operating_profile.dart';

class OperatingProfileCard extends StatefulWidget {
  const OperatingProfileCard({
    super.key,
    required this.restaurantId,
    this.backend,
  });

  final String restaurantId;
  final StoreOperatingProfileBackend? backend;

  @override
  State<OperatingProfileCard> createState() => _OperatingProfileCardState();
}

class _OperatingProfileCardState extends State<OperatingProfileCard> {
  StoreOperatingProfile? _profile;
  bool _busy = false;
  bool _unavailable = false;
  bool _failed = false;
  bool _changed = false;
  int _generation = 0;

  @override
  void didUpdateWidget(OperatingProfileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restaurantId != widget.restaurantId) {
      _generation++;
      _profile = null;
      _busy = _unavailable = _failed = _changed = false;
    }
  }

  Future<void> _run({bool capture = false}) async {
    if (_busy || (capture && _profile == null)) return;
    final generation = ++_generation;
    final restaurantId = widget.restaurantId;
    setState(() {
      _busy = true;
      _failed = _changed = false;
    });
    try {
      final backend = widget.backend ?? SupabaseStoreOperatingProfileBackend();
      final profile = capture
          ? await backend.capture(restaurantId, _profile!.revision)
          : await backend.load(restaurantId);
      if (!mounted || generation != _generation) return;
      if (profile != null && profile.restaurantId != restaurantId) {
        throw const FormatException('OPERATING_PROFILE_STORE_MISMATCH');
      }
      setState(() {
        _profile = profile;
        _unavailable = profile == null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _changed =
            error is PostgrestException &&
            error.message == 'OPERATING_PROFILE_CHANGED';
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final profile = _profile;
    return Card(
      key: const Key('operating_profile_card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.operatingProfileTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(l10n.operatingProfileDescription),
            if (_unavailable) Text(l10n.operatingProfileUnavailable),
            if (_failed)
              Text(
                _changed
                    ? l10n.operatingProfileChanged
                    : l10n.operatingProfileFailed,
              ),
            if (profile != null) ...[
              const SizedBox(height: 12),
              Text(
                profile.workflow == 'kitchen_floor'
                    ? l10n.operatingProfileDirectRoute
                    : l10n.operatingProfileTrayRoute,
              ),
              Text(
                profile.sourceMatches
                    ? l10n.operatingProfileCurrent
                    : l10n.operatingProfileNeedsCapture,
              ),
              if (profile.stations.isNotEmpty)
                Text(l10n.operatingProfileRecordedAssignments),
              for (final station in profile.stations)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(switch (station.kind) {
                    ServiceStationKind.kitchen =>
                      l10n.settingsPrintDestinationKitchen,
                    ServiceStationKind.tray =>
                      l10n.settingsPrintDestinationTray,
                    ServiceStationKind.floor =>
                      '${l10n.settingsPrintDestinationFloor} '
                          '${displayFloorLabel(station.storedFloor!)}',
                  }),
                  trailing: Text(
                    l10n.operatingProfileAccounts(station.userIds.length),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('operating_profile_load'),
                  onPressed: _busy ? null : _run,
                  child: Text(l10n.operatingProfileReview),
                ),
                if (profile != null && !profile.sourceMatches && !_unavailable)
                  FilledButton(
                    key: const Key('operating_profile_capture'),
                    onPressed: _busy || _changed
                        ? null
                        : () => _run(capture: true),
                    child: Text(l10n.operatingProfileCapture),
                  ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
