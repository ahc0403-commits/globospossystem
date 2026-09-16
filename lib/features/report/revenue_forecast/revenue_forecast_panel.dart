import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../report_excel_file.dart';
import 'revenue_forecast_defaults_service.dart';
import 'revenue_forecast_engine.dart';
import 'revenue_forecast_export.dart';
import 'revenue_forecast_profile_service.dart';

class RevenueForecastPanel extends StatefulWidget {
  const RevenueForecastPanel({
    super.key,
    required this.storeId,
    required this.businessType,
    required this.trainingStart,
    required this.trainingEnd,
    required this.observations,
    required this.canSaveProfile,
    this.storeName,
    this.profileRepository,
    this.defaultsRepository,
    this.saveExcelFile,
  });

  final String storeId;
  final ForecastBusinessType businessType;
  final DateTime trainingStart;
  final DateTime trainingEnd;
  final List<RevenueForecastObservation> observations;
  final bool canSaveProfile;
  final String? storeName;
  final RevenueForecastProfileRepository? profileRepository;
  final RevenueForecastDefaultsRepository? defaultsRepository;
  final ReportExcelFileSaver? saveExcelFile;

  @override
  State<RevenueForecastPanel> createState() => _RevenueForecastPanelState();
}

class _RevenueForecastPanelState extends State<RevenueForecastPanel> {
  final _engine = const RevenueForecastEngine();
  RevenueForecastProfileRepository? _profileRepository;
  RevenueForecastDefaultsRepository? _defaultsRepository;

  final _firstServe = TextEditingController();
  final _dining = TextEditingController();
  final _paymentWait = TextEditingController();
  final _cleanup = TextEditingController();
  final _kitchenRate = TextEditingController();
  final _checkerRate = TextEditingController();
  final _restaurantOperatingMinutes = TextEditingController();
  final _averageTicket = TextEditingController();
  final _machineCount = TextEditingController();
  final _photoOperatingMinutes = TextEditingController();
  final _freeSessions = TextEditingController();

  final List<_FloorInput> _floors = [_FloorInput()];
  final Set<int> _restaurantOperatingWeekdays = <int>{};
  final Set<int> _photoOperatingWeekdays = <int>{};
  RevenueForecastResult? _result;
  String? _errorCode;
  int _horizonMonths = 6;
  int _revision = 0;
  int _loadGeneration = 0;
  RevenueForecastOperationalDefaults? _periodDefaults;
  RestaurantForecastProfile? _savedRestaurantProfile;
  Map<RevenueForecastInputField, RevenueForecastInputEvidence>
  _restaurantEvidence = const {};
  bool _loadingProfile = false;
  bool _profileUnavailable = false;
  bool _defaultsApplied = false;
  bool _defaultsUnavailable = false;
  bool _usingSavedRestaurantProfile = false;
  bool _saving = false;
  bool _saved = false;
  bool _exporting = false;
  bool _hasDraftEdits = false;

  @override
  void initState() {
    super.initState();
    _profileRepository = _resolveProfileRepository();
    _defaultsRepository = _resolveDefaultsRepository();
    _loadProfile();
  }

  @override
  void didUpdateWidget(covariant RevenueForecastPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.businessType != widget.businessType ||
        oldWidget.profileRepository != widget.profileRepository ||
        oldWidget.defaultsRepository != widget.defaultsRepository) {
      _profileRepository = _resolveProfileRepository();
      _defaultsRepository = _resolveDefaultsRepository();
      _resetForStore();
      _loadProfile();
    } else if (oldWidget.trainingStart != widget.trainingStart ||
        oldWidget.trainingEnd != widget.trainingEnd ||
        !_sameObservations(oldWidget.observations, widget.observations)) {
      setState(() {
        _result = null;
        _errorCode = null;
      });
      if (_revision == 0 && !_hasDraftEdits) {
        _loadProfile(replaceDraft: true);
      }
    }
  }

  RevenueForecastProfileRepository? _resolveProfileRepository() {
    if (widget.profileRepository != null) return widget.profileRepository;
    try {
      return RevenueForecastProfileService(supabase);
    } catch (_) {
      return null;
    }
  }

  RevenueForecastDefaultsRepository? _resolveDefaultsRepository() {
    if (widget.defaultsRepository != null) return widget.defaultsRepository;
    try {
      return RevenueForecastDefaultsService(supabase);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _firstServe.dispose();
    _dining.dispose();
    _paymentWait.dispose();
    _cleanup.dispose();
    _kitchenRate.dispose();
    _checkerRate.dispose();
    _restaurantOperatingMinutes.dispose();
    _averageTicket.dispose();
    _machineCount.dispose();
    _photoOperatingMinutes.dispose();
    _freeSessions.dispose();
    for (final floor in _floors) {
      floor.dispose();
    }
    super.dispose();
  }

  void _resetForStore() {
    _loadGeneration += 1;
    _revision = 0;
    _result = null;
    _errorCode = null;
    _profileUnavailable = false;
    _defaultsApplied = false;
    _defaultsUnavailable = false;
    _periodDefaults = null;
    _savedRestaurantProfile = null;
    _restaurantEvidence = const {};
    _usingSavedRestaurantProfile = false;
    _saving = false;
    _exporting = false;
    _saved = false;
    _hasDraftEdits = false;
    _restaurantOperatingWeekdays.clear();
    _photoOperatingWeekdays.clear();
    for (final controller in [
      _firstServe,
      _dining,
      _paymentWait,
      _cleanup,
      _kitchenRate,
      _checkerRate,
      _restaurantOperatingMinutes,
      _averageTicket,
      _machineCount,
      _photoOperatingMinutes,
      _freeSessions,
    ]) {
      controller.clear();
    }
    for (final floor in _floors) {
      floor.dispose();
    }
    _floors
      ..clear()
      ..add(_FloorInput());
  }

  Future<void> _loadProfile({bool replaceDraft = false}) async {
    final generation = ++_loadGeneration;
    if (replaceDraft) _hasDraftEdits = false;
    setState(() {
      _loadingProfile = true;
      _profileUnavailable = false;
      _defaultsUnavailable = false;
    });
    RevenueForecastProfileSnapshot? snapshot;
    var profileUnavailable = _profileRepository == null;
    try {
      if (_profileRepository != null) {
        snapshot = await _profileRepository!.load(widget.storeId);
      }
    } catch (_) {
      profileUnavailable = true;
    }
    if (!mounted || generation != _loadGeneration) return;

    if (snapshot != null && snapshot.businessType == widget.businessType) {
      _revision = snapshot.revision;
      if (widget.businessType == ForecastBusinessType.restaurant) {
        _savedRestaurantProfile = snapshot.restaurantProfile;
      } else if (!_hasDraftEdits || replaceDraft) {
        _applyPhotoProfile(snapshot.photoProfile!);
        _defaultsApplied = false;
      }
    }

    if (widget.businessType == ForecastBusinessType.restaurant &&
        _defaultsRepository != null) {
      try {
        final defaults = await _defaultsRepository!.loadRestaurant(
          storeId: widget.storeId,
          trainingStart: widget.trainingStart,
          trainingEnd: widget.trainingEnd,
          observations: widget.observations,
        );
        if (!mounted || generation != _loadGeneration) return;
        _periodDefaults = defaults;
        if (defaults != null && (!_hasDraftEdits || replaceDraft)) {
          _applyRestaurantDefaults(defaults);
          _defaultsApplied = true;
          _usingSavedRestaurantProfile = false;
        } else if (defaults == null) {
          _defaultsUnavailable = true;
        }
      } catch (_) {
        if (!mounted || generation != _loadGeneration) return;
        _defaultsUnavailable = true;
      }
    } else if (widget.businessType == ForecastBusinessType.restaurant) {
      _defaultsUnavailable = true;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _profileUnavailable = profileUnavailable;
      _loadingProfile = false;
    });
  }

  void _applyRestaurantProfile(RestaurantForecastProfile profile) {
    for (final floor in _floors) {
      floor.dispose();
    }
    _floors
      ..clear()
      ..addAll(
        profile.floors.map(
          (floor) => _FloorInput(
            label: floor.label,
            tableCount: floor.tableCount.toString(),
            serviceRate: _editableNumber(floor.serviceUnitsPerHour),
          ),
        ),
      );
    _firstServe.text = _editableNumber(profile.seatedToFirstServeMinutes);
    _dining.text = _editableNumber(profile.diningMinutes);
    _paymentWait.text = _editableNumber(profile.paymentWaitMinutes);
    _cleanup.text = _editableNumber(profile.cleanupMinutes);
    _kitchenRate.text = _editableNumber(profile.kitchenUnitsPerHour);
    _checkerRate.text = _editableNumber(profile.checkerUnitsPerHour);
    _restaurantOperatingMinutes.text = profile.operatingMinutesPerDay
        .toString();
    _restaurantOperatingWeekdays
      ..clear()
      ..addAll(profile.operatingWeekdays);
    _averageTicket.text = _editableNumber(profile.averageTicketVnd);
  }

  void _applyRestaurantDefaults(RevenueForecastOperationalDefaults defaults) {
    _applyRestaurantProfile(defaults.profile);
    _restaurantEvidence = Map.unmodifiable(defaults.evidence);
    for (final entry in <RevenueForecastInputField, TextEditingController>{
      RevenueForecastInputField.firstServeMinutes: _firstServe,
      RevenueForecastInputField.diningMinutes: _dining,
      RevenueForecastInputField.paymentWaitMinutes: _paymentWait,
      RevenueForecastInputField.cleanupMinutes: _cleanup,
      RevenueForecastInputField.kitchenRate: _kitchenRate,
      RevenueForecastInputField.checkerRate: _checkerRate,
      RevenueForecastInputField.operatingMinutes: _restaurantOperatingMinutes,
      RevenueForecastInputField.averageTicket: _averageTicket,
    }.entries) {
      if (defaults.evidenceFor(entry.key).source ==
          RevenueForecastInputSource.unavailable) {
        entry.value.clear();
      }
    }
    if (defaults
            .evidenceFor(RevenueForecastInputField.floorServiceRate)
            .source ==
        RevenueForecastInputSource.unavailable) {
      for (final floor in _floors) {
        floor.serviceRate.clear();
      }
    }
  }

  void _applySavedRestaurantSettings() {
    final profile = _savedRestaurantProfile;
    if (profile == null) return;
    setState(() {
      _applyRestaurantProfile(profile);
      _restaurantEvidence = Map.unmodifiable({
        for (final field in RevenueForecastInputField.values)
          field: const RevenueForecastInputEvidence(
            source: RevenueForecastInputSource.savedProfile,
          ),
      });
      _usingSavedRestaurantProfile = true;
      _defaultsApplied = false;
      _hasDraftEdits = false;
      _result = null;
      _errorCode = null;
      _saved = false;
    });
  }

  void _applyPeriodAverageSettings() {
    final defaults = _periodDefaults;
    if (defaults == null) return;
    setState(() {
      _applyRestaurantDefaults(defaults);
      _usingSavedRestaurantProfile = false;
      _defaultsApplied = true;
      _hasDraftEdits = _revision > 0;
      _result = null;
      _errorCode = null;
      _saved = false;
    });
  }

  void _applyPhotoProfile(PhotoForecastProfile profile) {
    _machineCount.text = profile.machineCount.toString();
    _photoOperatingMinutes.text = profile.operatingMinutesPerDay.toString();
    _photoOperatingWeekdays
      ..clear()
      ..addAll(profile.operatingWeekdays);
    _freeSessions.text = profile.freeServiceSessionsPerDay.toString();
  }

  RestaurantForecastProfile _restaurantProfile() {
    final floors = _floors
        .map(
          (floor) => RestaurantFloorCapacity(
            label: floor.label.text.trim(),
            tableCount: _requiredInt(floor.tableCount.text),
            serviceUnitsPerHour: _requiredDouble(floor.serviceRate.text),
          ),
        )
        .toList(growable: false);
    return RestaurantForecastProfile(
      floors: floors,
      seatedToFirstServeMinutes: _requiredDouble(_firstServe.text),
      diningMinutes: _requiredDouble(_dining.text),
      paymentWaitMinutes: _requiredDouble(_paymentWait.text),
      cleanupMinutes: _requiredDouble(_cleanup.text),
      kitchenUnitsPerHour: _requiredDouble(_kitchenRate.text),
      checkerUnitsPerHour: _requiredDouble(_checkerRate.text),
      operatingMinutesPerDay: _requiredInt(_restaurantOperatingMinutes.text),
      operatingWeekdays: Set<int>.unmodifiable(_restaurantOperatingWeekdays),
      averageTicketVnd: _requiredVnd(_averageTicket.text),
    );
  }

  PhotoForecastProfile _photoProfile() => PhotoForecastProfile(
    machineCount: _requiredInt(_machineCount.text),
    operatingMinutesPerDay: _requiredInt(_photoOperatingMinutes.text),
    operatingWeekdays: Set<int>.unmodifiable(_photoOperatingWeekdays),
    freeServiceSessionsPerDay: _requiredInt(_freeSessions.text),
  );

  DateTime get _forecastEnd => DateTime.utc(
    widget.trainingEnd.year,
    widget.trainingEnd.month + _horizonMonths + 1,
    0,
  );

  void _calculate() {
    FocusScope.of(context).unfocus();
    try {
      final result = widget.businessType == ForecastBusinessType.restaurant
          ? _engine.forecastRestaurant(
              observations: widget.observations,
              trainingStart: widget.trainingStart,
              trainingEnd: widget.trainingEnd,
              forecastEnd: _forecastEnd,
              profile: _restaurantProfile(),
            )
          : _engine.forecastPhoto(
              observations: widget.observations,
              trainingStart: widget.trainingStart,
              trainingEnd: widget.trainingEnd,
              forecastEnd: _forecastEnd,
              profile: _photoProfile(),
            );
      setState(() {
        _result = result;
        _errorCode = null;
        _saved = false;
      });
    } on ForecastValidationException catch (error) {
      setState(() {
        _result = null;
        _errorCode = error.code;
      });
    } on FormatException {
      setState(() {
        _result = null;
        _errorCode = 'INVALID_SETTINGS';
      });
    } catch (_) {
      setState(() {
        _result = null;
        _errorCode = 'CALCULATION_FAILED';
      });
    }
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    if (_profileRepository == null) {
      setState(() => _errorCode = 'PROFILE_UNAVAILABLE');
      return;
    }
    final generation = _loadGeneration;
    final storeId = widget.storeId;
    final businessType = widget.businessType;
    bool isCurrentRequest() =>
        mounted &&
        generation == _loadGeneration &&
        widget.storeId == storeId &&
        widget.businessType == businessType;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _saved = false;
      _errorCode = null;
    });
    try {
      late final RevenueForecastProfileSnapshot snapshot;
      if (widget.businessType == ForecastBusinessType.restaurant) {
        final profile = _restaurantProfile();
        _engine.validateRestaurantProfile(profile);
        snapshot = await _profileRepository!.saveRestaurant(
          storeId: widget.storeId,
          expectedRevision: _revision,
          profile: profile,
        );
      } else {
        final profile = _photoProfile();
        _engine.validatePhotoProfile(profile);
        snapshot = await _profileRepository!.savePhoto(
          storeId: widget.storeId,
          expectedRevision: _revision,
          profile: profile,
        );
      }
      if (!isCurrentRequest()) return;
      setState(() {
        _revision = snapshot.revision;
        if (widget.businessType == ForecastBusinessType.restaurant) {
          _savedRestaurantProfile = snapshot.restaurantProfile;
        }
        _saved = true;
        _profileUnavailable = false;
        _defaultsApplied = false;
        _hasDraftEdits = false;
      });
    } on FormatException {
      if (isCurrentRequest()) {
        setState(() => _errorCode = 'INVALID_SETTINGS');
      }
    } on ForecastValidationException {
      if (isCurrentRequest()) {
        setState(() => _errorCode = 'INVALID_SETTINGS');
      }
    } catch (error) {
      if (!isCurrentRequest()) return;
      setState(() {
        _errorCode = error.toString().contains('FORECAST_PROFILE_CONFLICT')
            ? 'FORECAST_PROFILE_CONFLICT'
            : 'PROFILE_UNAVAILABLE';
      });
    } finally {
      if (isCurrentRequest()) setState(() => _saving = false);
    }
  }

  Future<void> _downloadForecast() async {
    final result = _result;
    if (result == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final settings = widget.businessType == ForecastBusinessType.restaurant
          ? <String, dynamic>{
              ...restaurantProfileToJson(_restaurantProfile()),
              'input_provenance': {
                for (final entry in _restaurantEvidence.entries)
                  entry.key.name: entry.value.toJson(),
              },
              if (_restaurantEvidence.values.any(
                    (item) =>
                        item.source ==
                        RevenueForecastInputSource.selectedPeriodAverage,
                  ) &&
                  _periodDefaults?.periodStart != null)
                'source_period_start': DateFormat(
                  'yyyy-MM-dd',
                ).format(_periodDefaults!.periodStart!),
              if (_restaurantEvidence.values.any(
                    (item) =>
                        item.source ==
                        RevenueForecastInputSource.selectedPeriodAverage,
                  ) &&
                  _periodDefaults?.periodEnd != null)
                'source_period_end': DateFormat(
                  'yyyy-MM-dd',
                ).format(_periodDefaults!.periodEnd!),
            }
          : photoProfileToJson(_photoProfile());
      final l10n = context.l10n;
      final locale = Localizations.localeOf(context).toString();
      final bytes = buildRevenueForecastWorkbook(
        RevenueForecastExportSnapshot(
          storeName: widget.storeName ?? widget.storeId,
          locale: locale,
          generatedAt: DateTime.now(),
          profileRevision: _revision,
          result: result,
          observations: widget.observations,
          settings: settings,
          copy: RevenueForecastExportCopy(
            summarySheet: l10n.revenueForecastResult,
            monthlySheet: l10n.revenueForecastMonthly,
            inputsSheet: l10n.revenueForecastSettings,
            improvementsSheet: l10n.revenueForecastImprovements,
            forecastTitle: l10n.revenueForecastTitle,
            businessTypeLabel: l10n.revenueForecastExportBusinessType,
            businessType: widget.businessType == ForecastBusinessType.restaurant
                ? l10n.revenueForecastRestaurant
                : l10n.revenueForecastPhoto,
            trainingPeriod: l10n.revenueForecastTrainingPeriod,
            forecastHorizon: l10n.revenueForecastHorizon,
            modelQuality: l10n.revenueForecastModelQuality('R²'),
            profileRevision: l10n.revenueForecastProfileRevision(_revision),
            expectedRevenue: l10n.revenueForecastExpectedRevenue,
            demandRevenue: l10n.revenueForecastDemandRevenue,
            capacityLimit: l10n.revenueForecastCapacityLimit,
            completeMonth: l10n.revenueForecastCompleteMonth,
            partialMonth: l10n.revenueForecastPartialMonth,
            extraRevenue: l10n.revenueForecastExtraRevenue('VND'),
            nextBottleneck: l10n.revenueForecastNextBottleneck(''),
            notGuarantee: l10n.revenueForecastNotGuarantee,
            store: l10n.store,
            status: l10n.status,
            date: l10n.date,
            generatedAt: l10n.revenueForecastExportGeneratedAt,
            timezone: l10n.revenueForecastExportTimezone,
            field: l10n.revenueForecastExportField,
            value: l10n.revenueForecastExportValue,
            current: l10n.revenueForecastExportCurrent,
            proposed: l10n.revenueForecastExportProposed,
            servedUnits: l10n.revenueForecastExportServedUnits,
            actualRevenue: l10n.revenueForecastExportActualRevenue,
            dineInRevenue: l10n.revenueForecastExportDineInRevenue,
            observedUnits: l10n.revenueForecastExportObservedUnits,
            firstReachedMonth: l10n.revenueForecastExportFirstReached,
            maintainedForThreeMonths: l10n.revenueForecastExportMaintained,
            monthlyTarget: l10n.revenueForecastExportMonthlyTarget,
            localeLabel: l10n.language,
            yes: l10n.yes,
            no: l10n.no,
            goalStatuses: {
              ForecastGoalStatus.reached: l10n.revenueForecastGoalReached(''),
              ForecastGoalStatus.capacityExceeded:
                  l10n.revenueForecastGoalCapacityExceeded,
              ForecastGoalStatus.demandNotReached:
                  l10n.revenueForecastGoalDemandNotReached,
              ForecastGoalStatus.insufficientEvidence:
                  l10n.revenueForecastInsufficientDays,
            },
            recommendationKinds: {
              for (final kind in ForecastRecommendationKind.values)
                kind: _recommendationName(context, kind),
            },
            bottlenecks: {
              for (final name in const [
                'demand',
                'kitchen',
                'checker',
                'table_turnover',
                'floor_service',
                'photo_capacity',
                'closed',
              ])
                name: _bottleneck(context, name),
            },
          ),
        ),
      );
      final saver = widget.saveExcelFile ?? saveReportExcelFile;
      await saver(
        name:
            'revenue_forecast_${widget.storeId}_${DateFormat('yyyyMMdd').format(DateTime.now())}',
        bytes: Uint8List.fromList(bytes),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.revenueForecastDownloadRequested)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.revenueForecastDownloadFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _markDirty(String _) {
    setState(() {
      _hasDraftEdits = true;
      _result = null;
      _saved = false;
      _errorCode = null;
    });
  }

  void _markRestaurantFieldDirty(RevenueForecastInputField field, String _) {
    setState(() {
      _restaurantEvidence = Map.unmodifiable({
        ..._restaurantEvidence,
        field: const RevenueForecastInputEvidence(
          source: RevenueForecastInputSource.manualAssumption,
        ),
      });
      _usingSavedRestaurantProfile = false;
      _hasDraftEdits = true;
      _result = null;
      _saved = false;
      _errorCode = null;
    });
  }

  void _toggleOperatingWeekday(Set<int> weekdays, int weekday) {
    setState(() {
      if (!weekdays.add(weekday)) weekdays.remove(weekday);
      _hasDraftEdits = true;
      _result = null;
      _saved = false;
      _errorCode = null;
    });
  }

  void _addFloor() => setState(() {
    _floors.add(_FloorInput());
    _restaurantEvidence = Map.unmodifiable({
      ..._restaurantEvidence,
      RevenueForecastInputField.floorLabel: const RevenueForecastInputEvidence(
        source: RevenueForecastInputSource.manualAssumption,
      ),
      RevenueForecastInputField.tableCount: const RevenueForecastInputEvidence(
        source: RevenueForecastInputSource.manualAssumption,
      ),
      RevenueForecastInputField.floorServiceRate:
          const RevenueForecastInputEvidence(
            source: RevenueForecastInputSource.manualAssumption,
          ),
    });
    _hasDraftEdits = true;
    _result = null;
    _saved = false;
  });

  void _removeFloor(int index) {
    if (_floors.length == 1) return;
    setState(() {
      _floors.removeAt(index).dispose();
      _restaurantEvidence = Map.unmodifiable({
        ..._restaurantEvidence,
        RevenueForecastInputField.floorLabel:
            const RevenueForecastInputEvidence(
              source: RevenueForecastInputSource.manualAssumption,
            ),
        RevenueForecastInputField.tableCount:
            const RevenueForecastInputEvidence(
              source: RevenueForecastInputSource.manualAssumption,
            ),
        RevenueForecastInputField.floorServiceRate:
            const RevenueForecastInputEvidence(
              source: RevenueForecastInputSource.manualAssumption,
            ),
      });
      _hasDraftEdits = true;
      _result = null;
      _saved = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dateFormat = DateFormat.yMMMd(
      Localizations.localeOf(context).toString(),
    );
    return PosDataPanel(
      title: l10n.revenueForecastTitle,
      subtitle: l10n.revenueForecastSubtitle,
      trailing: _loadingProfile
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _revision > 0 || _hasDraftEdits
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (_revision > 0)
                  Chip(
                    label: Text(l10n.revenueForecastProfileRevision(_revision)),
                  ),
                if (_hasDraftEdits)
                  Chip(
                    avatar: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(l10n.revenueForecastUnsaved),
                  ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: Icon(
                  widget.businessType == ForecastBusinessType.restaurant
                      ? Icons.restaurant_outlined
                      : Icons.photo_camera_outlined,
                  size: 18,
                ),
                label: Text(
                  widget.businessType == ForecastBusinessType.restaurant
                      ? l10n.revenueForecastRestaurant
                      : l10n.revenueForecastPhoto,
                ),
              ),
              Text(
                '${l10n.revenueForecastTrainingPeriod}: '
                '${dateFormat.format(widget.trainingStart)} – '
                '${dateFormat.format(widget.trainingEnd)}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInputSummary(),
          if (_defaultsApplied) ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              key: const Key('revenue_forecast_defaults_applied'),
              label: (_periodDefaults?.hasUnavailableInputs ?? false)
                  ? l10n.revenueForecastDefaultsAppliedWithFallbacks
                  : l10n.revenueForecastDefaultsApplied,
              color: PosColors.info,
              icon: Icons.auto_awesome_outlined,
            ),
          ],
          if (_defaultsUnavailable) ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              key: const Key('revenue_forecast_defaults_unavailable'),
              label: l10n.revenueForecastDefaultsUnavailable,
              color: PosColors.warning,
              icon: Icons.table_restaurant_outlined,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: PosSecondaryButton(
                label: l10n.retry,
                icon: Icons.refresh,
                onPressed: _loadingProfile
                    ? null
                    : () => _loadProfile(replaceDraft: true),
              ),
            ),
          ],
          if (widget.businessType == ForecastBusinessType.restaurant &&
              (_savedRestaurantProfile != null || _periodDefaults != null)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_savedRestaurantProfile != null &&
                    !_usingSavedRestaurantProfile)
                  PosSecondaryButton(
                    key: const Key('revenue_forecast_apply_saved_profile'),
                    label: l10n.revenueForecastApplySavedProfile,
                    icon: Icons.history_outlined,
                    onPressed: _applySavedRestaurantSettings,
                  ),
                if (_periodDefaults != null &&
                    (_usingSavedRestaurantProfile || !_defaultsApplied))
                  PosSecondaryButton(
                    key: const Key('revenue_forecast_apply_period_average'),
                    label: l10n.revenueForecastApplyPeriodAverage,
                    icon: Icons.auto_graph_outlined,
                    onPressed: _applyPeriodAverageSettings,
                  ),
              ],
            ),
          ],
          if (_profileUnavailable || _errorCode == 'PROFILE_UNAVAILABLE') ...[
            const SizedBox(height: 12),
            PosExceptionAlert(label: l10n.revenueForecastProfileUnavailable),
            if (_profileRepository != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: PosSecondaryButton(
                  label: l10n.retry,
                  icon: Icons.refresh,
                  onPressed: _loadingProfile
                      ? null
                      : () => _loadProfile(replaceDraft: true),
                ),
              ),
            ],
          ],
          if (_saved) ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              label: l10n.revenueForecastSaved,
              color: PosColors.success,
              icon: Icons.check_circle_outline,
            ),
          ],
          if (_errorCode != null && _errorCode != 'PROFILE_UNAVAILABLE') ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              key: const Key('revenue_forecast_error'),
              label: _localizedError(_errorCode!),
              color: PosColors.danger,
              icon: Icons.error_outline,
            ),
            if (_errorCode == 'FORECAST_PROFILE_CONFLICT' &&
                _profileRepository != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: PosSecondaryButton(
                  label: l10n.retry,
                  icon: Icons.refresh,
                  onPressed: _loadingProfile
                      ? null
                      : () => _loadProfile(replaceDraft: true),
                ),
              ),
            ],
          ],
          const SizedBox(height: 20),
          Text(
            l10n.revenueForecastSettings,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            widget.businessType == ForecastBusinessType.restaurant
                ? l10n.revenueForecastSettingsHint
                : l10n.revenueForecastPhotoSettingsHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (widget.businessType == ForecastBusinessType.restaurant)
            _buildRestaurantSettings()
          else
            _buildPhotoSettings(),
          const SizedBox(height: 16),
          _buildActions(),
          if (_result != null) ...[
            const SizedBox(height: 24),
            _ForecastResults(result: _result!),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                key: const Key('revenue_forecast_download'),
                height: 48,
                child: PosSecondaryButton(
                  label: _exporting
                      ? l10n.revenueForecastDownloading
                      : l10n.revenueForecastDownload,
                  icon: Icons.download_outlined,
                  onPressed: _exporting ? null : _downloadForecast,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRestaurantSettings() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _floors.length; index++) ...[
          _FloorInputRow(
            key: ValueKey(_floors[index]),
            input: _floors[index],
            index: index,
            canRemove: _floors.length > 1,
            onRemove: () => _removeFloor(index),
            onLabelChanged: (value) => _markRestaurantFieldDirty(
              RevenueForecastInputField.floorLabel,
              value,
            ),
            onTableCountChanged: (value) => _markRestaurantFieldDirty(
              RevenueForecastInputField.tableCount,
              value,
            ),
            onServiceRateChanged: (value) => _markRestaurantFieldDirty(
              RevenueForecastInputField.floorServiceRate,
              value,
            ),
            labelHelper: _restaurantEvidenceText(
              RevenueForecastInputField.floorLabel,
            ),
            tableCountHelper: _restaurantEvidenceText(
              RevenueForecastInputField.tableCount,
            ),
            serviceRateHelper: _restaurantEvidenceText(
              RevenueForecastInputField.floorServiceRate,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: PosSecondaryButton(
            label: l10n.revenueForecastAddFloor,
            icon: Icons.add,
            onPressed: _addFloor,
          ),
        ),
        const SizedBox(height: 16),
        _ForecastFieldGrid(
          children: [
            _ForecastNumberField(
              controller: _firstServe,
              label: l10n.revenueForecastFirstServeMinutes,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.firstServeMinutes,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.firstServeMinutes,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _dining,
              label: l10n.revenueForecastDiningMinutes,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.diningMinutes,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.diningMinutes,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _paymentWait,
              label: l10n.revenueForecastPaymentWaitMinutes,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.paymentWaitMinutes,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.paymentWaitMinutes,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _cleanup,
              label: l10n.revenueForecastCleanupMinutes,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.cleanupMinutes,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.cleanupMinutes,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _kitchenRate,
              label: l10n.revenueForecastKitchenRate,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.kitchenRate,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.kitchenRate,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _checkerRate,
              label: l10n.revenueForecastCheckerRate,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.checkerRate,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.checkerRate,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _restaurantOperatingMinutes,
              label: l10n.revenueForecastOperatingMinutes,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.operatingMinutes,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.operatingMinutes,
                value,
              ),
            ),
            _ForecastNumberField(
              controller: _averageTicket,
              label: l10n.revenueForecastAverageTicket,
              helperText: _restaurantEvidenceText(
                RevenueForecastInputField.averageTicket,
              ),
              onChanged: (value) => _markRestaurantFieldDirty(
                RevenueForecastInputField.averageTicket,
                value,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildOperatingWeekdays(
          weekdays: _restaurantOperatingWeekdays,
          keyPrefix: 'restaurant',
        ),
      ],
    );
  }

  String? _restaurantEvidenceText(RevenueForecastInputField field) {
    final evidence = _restaurantEvidence[field];
    if (evidence == null) return null;
    final l10n = context.l10n;
    final source = switch (evidence.source) {
      RevenueForecastInputSource.selectedPeriodAverage =>
        evidence.sampleCount > 0
            ? l10n.revenueForecastSourcePeriodAverage(
                evidence.sampleCount,
                evidence.observedDays,
              )
            : l10n.revenueForecastSourcePeriodAverageDays(
                evidence.observedDays,
              ),
      RevenueForecastInputSource.registeredConfiguration =>
        l10n.revenueForecastSourceRegisteredConfiguration,
      RevenueForecastInputSource.savedProfile =>
        l10n.revenueForecastSourceSavedProfile,
      RevenueForecastInputSource.manualAssumption =>
        l10n.revenueForecastSourceManualAssumption,
      RevenueForecastInputSource.unavailable =>
        l10n.revenueForecastSourceUnavailable,
    };
    return evidence.isProxy
        ? '$source · ${l10n.revenueForecastSourceProxy}'
        : source;
  }

  Widget _buildInputSummary() {
    final start = DateTime.utc(
      widget.trainingStart.year,
      widget.trainingStart.month,
      widget.trainingStart.day,
    );
    final end = DateTime.utc(
      widget.trainingEnd.year,
      widget.trainingEnd.month,
      widget.trainingEnd.day,
    );
    final included = widget.observations
        .where((row) {
          final date = DateTime.utc(
            row.date.year,
            row.date.month,
            row.date.day,
          );
          return !date.isBefore(start) && !date.isAfter(end);
        })
        .toList(growable: false);
    final observedDates = included
        .map((row) => DateTime.utc(row.date.year, row.date.month, row.date.day))
        .toSet()
        .length;
    final calendarDays = end.isBefore(start)
        ? 0
        : end.difference(start).inDays + 1;
    final actualRevenue = included.fold<double>(
      0,
      (sum, row) => sum + (row.revenueVnd.isFinite ? row.revenueVnd : 0),
    );
    return PosExceptionAlert(
      key: const Key('revenue_forecast_input_summary'),
      label: context.l10n.revenueForecastInputSummary(
        observedDates,
        calendarDays,
        _money(context, actualRevenue),
      ),
      color: observedDates >= minimumForecastTrainingDays
          ? PosColors.info
          : PosColors.warning,
      icon: Icons.fact_check_outlined,
    );
  }

  Widget _buildPhotoSettings() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PosExceptionAlert(
          label: l10n.revenueForecastPhotoPolicy,
          color: PosColors.info,
          icon: Icons.lock_clock_outlined,
        ),
        const SizedBox(height: 16),
        _ForecastFieldGrid(
          children: [
            _ForecastNumberField(
              controller: _machineCount,
              label: l10n.revenueForecastMachineCount,
              onChanged: _markDirty,
            ),
            _ForecastNumberField(
              controller: _photoOperatingMinutes,
              label: l10n.revenueForecastOperatingMinutes,
              onChanged: _markDirty,
            ),
            _ForecastNumberField(
              controller: _freeSessions,
              label: l10n.revenueForecastFreeSessions,
              onChanged: _markDirty,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildOperatingWeekdays(
          weekdays: _photoOperatingWeekdays,
          keyPrefix: 'photo',
        ),
      ],
    );
  }

  Widget _buildOperatingWeekdays({
    required Set<int> weekdays,
    required String keyPrefix,
  }) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    return Semantics(
      container: true,
      label: l10n.revenueForecastOperatingDays,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.revenueForecastOperatingDays,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.revenueForecastOperatingDaysHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (
                var weekday = DateTime.monday;
                weekday <= DateTime.sunday;
                weekday++
              )
                FilterChip(
                  key: Key('revenue_forecast_weekday_${keyPrefix}_$weekday'),
                  label: Text(
                    DateFormat.E(locale).format(DateTime.utc(2024, 1, weekday)),
                  ),
                  selected: weekdays.contains(weekday),
                  onSelected: (_) => _toggleOperatingWeekday(weekdays, weekday),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = <Widget>[
          DropdownButtonFormField<int>(
            key: const Key('revenue_forecast_horizon'),
            initialValue: _horizonMonths,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.revenueForecastHorizon,
              border: const OutlineInputBorder(),
            ),
            items: [3, 6, 12, 24]
                .map(
                  (months) => DropdownMenuItem(
                    value: months,
                    child: Text(l10n.revenueForecastMonths(months)),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _horizonMonths = value;
                _result = null;
              });
            },
          ),
          Semantics(
            button: true,
            label: l10n.revenueForecastCalculate,
            child: SizedBox(
              key: const Key('revenue_forecast_calculate'),
              height: 48,
              child: PosPrimaryButton(
                label: l10n.revenueForecastCalculate,
                icon: Icons.auto_graph,
                onPressed: _calculate,
              ),
            ),
          ),
          if (widget.canSaveProfile)
            Semantics(
              button: true,
              label: l10n.revenueForecastSaveProfile,
              child: SizedBox(
                key: const Key('revenue_forecast_save_profile'),
                height: 48,
                child: PosSecondaryButton(
                  label: _saving
                      ? l10n.revenueForecastSaving
                      : l10n.revenueForecastSaveProfile,
                  icon: Icons.save_outlined,
                  onPressed: _saving ? null : _saveProfile,
                ),
              ),
            ),
        ];
        final narrow =
            constraints.maxWidth < 900 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.5;
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 56, child: controls.first),
              const SizedBox(height: 10),
              for (final control in controls.skip(1)) ...[
                control,
                const SizedBox(height: 10),
              ],
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 220, child: controls.first),
            const SizedBox(width: 12),
            ...controls
                .skip(1)
                .expand((control) => [control, const SizedBox(width: 12)]),
          ],
        );
      },
    );
  }

  String _localizedError(String code) {
    final l10n = context.l10n;
    return switch (code) {
      'TRAINING_PERIOD_TOO_SHORT' => l10n.revenueForecastInsufficientDays,
      'TRAINING_DAYS_INCOMPLETE' ||
      'DUPLICATE_TRAINING_DAY' => l10n.revenueForecastIncompleteDays,
      'CLOSED_DAY_HAS_REVENUE' => l10n.revenueForecastClosedDayData,
      'NO_REVENUE_SIGNAL' ||
      'REGRESSION_SINGULAR' => l10n.revenueForecastNoRevenueSignal,
      'FORECAST_PROFILE_CONFLICT' => l10n.revenueForecastProfileConflict,
      'INVALID_SETTINGS' ||
      'INVALID_REVENUE' ||
      'INVALID_DINE_IN_REVENUE' ||
      'INVALID_UNITS' ||
      'TRAINING_RANGE_INVALID' ||
      'FORECAST_END_BEFORE_START' ||
      'RESTAURANT_PROFILE_INVALID' ||
      'PHOTO_PROFILE_INVALID' ||
      'PHOTO_SERVICE_EXCEEDS_CAPACITY' => l10n.revenueForecastInvalidSettings,
      _ => l10n.revenueForecastCalculationFailed,
    };
  }
}

class _ForecastResults extends StatelessWidget {
  const _ForecastResults({required this.result});

  final RevenueForecastResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final representative = result.months.firstWhere(
      (month) => month.isCompleteMonth,
      orElse: () => result.months.first,
    );
    return Column(
      key: const Key('revenue_forecast_result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.revenueForecastResult,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        _ResponsiveStatCards(
          cards: [
            PosStatCard(
              label: l10n.revenueForecastExpectedRevenue,
              value: _money(context, representative.forecastRevenueVnd),
              supporting: _month(context, representative.month),
              tone: PosColors.success,
            ),
            PosStatCard(
              label: l10n.revenueForecastDemandRevenue,
              value: _money(context, representative.demandRevenueVnd),
              supporting: _month(context, representative.month),
            ),
            PosStatCard(
              label: l10n.revenueForecastCapacityLimit,
              value: _money(context, representative.capacityRevenueVnd),
              supporting: _bottleneck(context, _dominantBottleneck(result)),
              tone: PosColors.warning,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _ModelExplanation(result: result),
        if (result.usesEquivalentPhotoSessions) ...[
          const SizedBox(height: 8),
          PosExceptionAlert(
            label: l10n.revenueForecastEquivalentPhotoSessions,
            color: PosColors.info,
            icon: Icons.info_outline,
          ),
        ],
        const SizedBox(height: 18),
        _GoalCards(goals: result.goals),
        const SizedBox(height: 18),
        Text(
          l10n.revenueForecastMonthly,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (final month in result.months) _MonthlyResultRow(month: month),
        const SizedBox(height: 18),
        if (result.businessType == ForecastBusinessType.restaurant) ...[
          PosExceptionAlert(
            label: l10n.revenueForecastDiningProtection,
            color: PosColors.info,
            icon: Icons.restaurant_outlined,
          ),
          const SizedBox(height: 8),
          _RecommendationList(recommendations: result.recommendations),
        ] else
          PosExceptionAlert(
            label: l10n.revenueForecastPhotoNoRecommendations,
            color: PosColors.info,
            icon: Icons.info_outline,
          ),
        const SizedBox(height: 12),
        Text(
          l10n.revenueForecastNotGuarantee,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
      ],
    );
  }
}

class _ModelExplanation extends StatelessWidget {
  const _ModelExplanation({required this.result});

  final RevenueForecastResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final number = NumberFormat('#,##0.##', locale);
    final regression = result.regression;
    final coefficients = regression.coefficients;
    final equation =
        'ŷ = ${number.format(coefficients[0])} + '
        '${number.format(coefficients[1])} × '
        '(d − ${number.format(regression.centerDay)}) + Σ weekday';
    final weekdayChips = <Widget>[];
    for (var index = 0; index < 6; index++) {
      final weekday = DateTime.utc(2026, 1, 6 + index);
      weekdayChips.add(
        _ForecastPill(
          label:
              '${l10n.revenueForecastWeekdayEffect(DateFormat.E(locale).format(weekday))}: '
              '${number.format(coefficients[index + 2])}',
        ),
      );
    }
    return Semantics(
      container: true,
      label: '${l10n.revenueForecastEquation}. $equation',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: PosColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.revenueForecastEquation,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            SelectableText(equation),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ForecastPill(
                  label:
                      '${l10n.revenueForecastTrendCoefficient}: '
                      '${number.format(coefficients[1])}',
                ),
                _ForecastPill(
                  label:
                      '${l10n.revenueForecastRmse}: '
                      '${number.format(regression.rmse)}',
                ),
                ...weekdayChips,
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.revenueForecastModelQuality(
                regression.rSquared.toStringAsFixed(2),
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.revenueForecastBacktestTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            if (result.backtest.foldCount == 0)
              Text(
                l10n.revenueForecastBacktestInsufficient,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...[
              Text(
                l10n.revenueForecastBacktestSummary(
                  result.backtest.foldCount,
                  _backtestValue(context, result, result.backtest.mae!),
                  result.backtest.wape == null
                      ? l10n.revenueForecastNotAvailable
                      : NumberFormat.percentPattern(
                          locale,
                        ).format(result.backtest.wape),
                  result.backtest.weekdayBaselineMae == null
                      ? l10n.revenueForecastNotAvailable
                      : _backtestValue(
                          context,
                          result,
                          result.backtest.weekdayBaselineMae!,
                        ),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(switch (result.backtest.beatsWeekdayBaseline) {
                true => l10n.revenueForecastBacktestBetter,
                false => l10n.revenueForecastBacktestNotBetter,
                null => l10n.revenueForecastBacktestBaselineUnavailable,
              }, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ForecastPill extends StatelessWidget {
  const _ForecastPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: PosColors.panelMuted,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: PosColors.border),
    ),
    child: Text(label),
  );
}

class _ResponsiveStatCards extends StatelessWidget {
  const _ResponsiveStatCards({required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900
          ? 3
          : constraints.maxWidth >= 560
          ? 2
          : 1;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final card in cards) SizedBox(width: width, child: card),
        ],
      );
    },
  );
}

class _GoalCards extends StatelessWidget {
  const _GoalCards({required this.goals});

  final List<ForecastGoalResult> goals;

  @override
  Widget build(BuildContext context) => _ResponsiveStatCards(
    cards: [
      for (final goal in goals)
        PosStatCard(
          label: context.l10n.revenueForecastGoalLabel(
            _money(context, goal.targetVnd),
          ),
          value: _goalStatus(context, goal),
          supporting: goal.status == ForecastGoalStatus.reached
              ? goal.maintainedForThreeMonths
                    ? context.l10n.revenueForecastGoalMaintained
                    : context.l10n.revenueForecastGoalNotYetMaintained
              : null,
          tone: goal.status == ForecastGoalStatus.reached
              ? PosColors.success
              : PosColors.warning,
        ),
    ],
  );
}

class _MonthlyResultRow extends StatelessWidget {
  const _MonthlyResultRow({required this.month});

  final ForecastMonthResult month;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final utilization = month.capacityRevenueVnd <= 0
        ? null
        : month.forecastRevenueVnd / month.capacityRevenueVnd;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PosColors.panelMuted,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _month(context, month.month),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        month.isCompleteMonth
                            ? l10n.revenueForecastCompleteMonth
                            : l10n.revenueForecastPartialMonth,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _money(context, month.forecastRevenueVnd),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.revenueForecastDemandRevenue}: '
              '${_money(context, month.demandRevenueVnd)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 2),
            Text(
              '${l10n.revenueForecastCapacityLimit}: '
              '${_money(context, month.capacityRevenueVnd)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (utilization != null) ...[
              const SizedBox(height: 2),
              Text(
                l10n.revenueForecastUtilization(
                  NumberFormat.percentPattern(
                    Localizations.localeOf(context).toString(),
                  ).format(utilization.clamp(0, 1)),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecommendationList extends StatelessWidget {
  const _RecommendationList({required this.recommendations});

  final List<ForecastRecommendation> recommendations;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.revenueForecastImprovements,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.revenueForecastImprovementDisclaimer,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final recommendation in recommendations)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: PosColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _recommendationName(context, recommendation.kind),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  recommendation.extraRevenueVnd > 0
                      ? l10n.revenueForecastExtraRevenue(
                          _money(context, recommendation.extraRevenueVnd),
                        )
                      : l10n.revenueForecastNoUplift,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.revenueForecastChange(
                    _recommendationValue(
                      context,
                      recommendation.kind,
                      recommendation.currentValue,
                    ),
                    _recommendationValue(
                      context,
                      recommendation.kind,
                      recommendation.proposedValue,
                    ),
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (recommendation.extraServedUnits > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.revenueForecastExtraUnits(
                      NumberFormat.decimalPattern(
                        Localizations.localeOf(context).toString(),
                      ).format(recommendation.extraServedUnits),
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  l10n.revenueForecastNextBottleneck(
                    _bottleneck(context, recommendation.nextBottleneck),
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FloorInputRow extends StatelessWidget {
  const _FloorInputRow({
    super.key,
    required this.input,
    required this.index,
    required this.canRemove,
    required this.onRemove,
    required this.onLabelChanged,
    required this.onTableCountChanged,
    required this.onServiceRateChanged,
    this.labelHelper,
    this.tableCountHelper,
    this.serviceRateHelper,
  });

  final _FloorInput input;
  final int index;
  final bool canRemove;
  final VoidCallback onRemove;
  final ValueChanged<String> onLabelChanged;
  final ValueChanged<String> onTableCountChanged;
  final ValueChanged<String> onServiceRateChanged;
  final String? labelHelper;
  final String? tableCountHelper;
  final String? serviceRateHelper;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fields = [
        _ForecastNumberField(
          controller: input.label,
          label: context.l10n.revenueForecastFloorLabel,
          numeric: false,
          helperText: labelHelper,
          onChanged: onLabelChanged,
        ),
        _ForecastNumberField(
          controller: input.tableCount,
          label: context.l10n.revenueForecastTableCount,
          helperText: tableCountHelper,
          onChanged: onTableCountChanged,
        ),
        _ForecastNumberField(
          controller: input.serviceRate,
          label: context.l10n.revenueForecastFloorServiceRate,
          helperText: serviceRateHelper,
          onChanged: onServiceRateChanged,
        ),
      ];
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: PosColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${context.l10n.revenueForecastFloorLabel} ${index + 1}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Semantics(
                  button: true,
                  label: context.l10n.revenueForecastRemoveFloor,
                  child: IconButton(
                    key: Key('revenue_forecast_remove_floor_$index'),
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    tooltip: context.l10n.revenueForecastRemoveFloor,
                    onPressed: canRemove ? onRemove : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ],
            ),
            _ForecastFieldGrid(children: fields),
          ],
        ),
      );
    },
  );
}

class _ForecastFieldGrid extends StatelessWidget {
  const _ForecastFieldGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 850
          ? 3
          : constraints.maxWidth >= 540
          ? 2
          : 1;
      final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

class _ForecastNumberField extends StatelessWidget {
  const _ForecastNumberField({
    required this.controller,
    required this.label,
    this.numeric = true,
    this.helperText,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool numeric;
  final String? helperText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    textField: true,
    label: label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          textInputAction: TextInputAction.next,
          onChanged: onChanged,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: helperText,
            helperMaxLines: 3,
          ),
        ),
      ],
    ),
  );
}

class _FloorInput {
  _FloorInput({
    String label = '',
    String tableCount = '',
    String serviceRate = '',
  }) : label = TextEditingController(text: label),
       tableCount = TextEditingController(text: tableCount),
       serviceRate = TextEditingController(text: serviceRate);

  final TextEditingController label;
  final TextEditingController tableCount;
  final TextEditingController serviceRate;

  void dispose() {
    label.dispose();
    tableCount.dispose();
    serviceRate.dispose();
  }
}

double _requiredDouble(String input) {
  final normalized = input.trim().replaceAll(' ', '');
  if (normalized.isEmpty) throw const FormatException('required');
  final commaCount = ','.allMatches(normalized).length;
  final dotCount = '.'.allMatches(normalized).length;
  if (commaCount > 1 || (commaCount > 0 && dotCount > 0)) {
    throw const FormatException('ambiguous number');
  }
  if (commaCount == 1 && RegExp(r',\d{3}$').hasMatch(normalized)) {
    throw const FormatException('ambiguous number');
  }
  final parseable = commaCount == 1
      ? normalized.replaceAll(',', '.')
      : normalized;
  final value = double.tryParse(parseable);
  if (value == null || !value.isFinite) throw const FormatException('number');
  return value;
}

int _requiredInt(String input) {
  final normalized = input.trim().replaceAll(' ', '');
  if (!RegExp(r'^\d+$').hasMatch(normalized)) {
    throw const FormatException('integer');
  }
  final value = int.tryParse(normalized);
  if (value == null) throw const FormatException('integer');
  return value;
}

double _requiredVnd(String input) {
  final normalized = input.trim().replaceAll(' ', '');
  if (RegExp(r'^\d+$').hasMatch(normalized)) {
    return double.parse(normalized);
  }
  if (RegExp(r'^\d{1,3}([,.]\d{3})+$').hasMatch(normalized)) {
    return double.parse(normalized.replaceAll(RegExp(r'[,.]'), ''));
  }
  throw const FormatException('VND');
}

String _editableNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

bool _sameObservations(
  List<RevenueForecastObservation> left,
  List<RevenueForecastObservation> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.date != b.date ||
        a.revenueVnd != b.revenueVnd ||
        a.dineInRevenueVnd != b.dineInRevenueVnd ||
        a.units != b.units) {
      return false;
    }
  }
  return true;
}

String _money(BuildContext context, double value) =>
    '${NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).format(value.round())} VND';

String _backtestValue(
  BuildContext context,
  RevenueForecastResult result,
  double value,
) => result.businessType == ForecastBusinessType.restaurant
    ? _money(context, value)
    : context.l10n.revenueForecastSessionsValue(
        NumberFormat(
          '#,##0.##',
          Localizations.localeOf(context).toString(),
        ).format(value),
      );

String _month(BuildContext context, DateTime value) =>
    DateFormat.yMMMM(Localizations.localeOf(context).toString()).format(value);

String _goalStatus(BuildContext context, ForecastGoalResult goal) {
  final l10n = context.l10n;
  return switch (goal.status) {
    ForecastGoalStatus.reached => l10n.revenueForecastGoalReached(
      _month(context, goal.firstReachedMonth!),
    ),
    ForecastGoalStatus.capacityExceeded =>
      l10n.revenueForecastGoalCapacityExceeded,
    ForecastGoalStatus.demandNotReached =>
      l10n.revenueForecastGoalDemandNotReached,
    ForecastGoalStatus.insufficientEvidence =>
      l10n.revenueForecastInsufficientDays,
  };
}

String _recommendationName(
  BuildContext context,
  ForecastRecommendationKind kind,
) => switch (kind) {
  ForecastRecommendationKind.tableTurnover =>
    context.l10n.revenueForecastImproveTurnover,
  ForecastRecommendationKind.kitchen =>
    context.l10n.revenueForecastImproveKitchen,
  ForecastRecommendationKind.checker =>
    context.l10n.revenueForecastImproveChecker,
  ForecastRecommendationKind.floorService =>
    context.l10n.revenueForecastImproveFloor,
  ForecastRecommendationKind.nonDiningWait =>
    context.l10n.revenueForecastImproveWait,
  ForecastRecommendationKind.operatingHours =>
    context.l10n.revenueForecastImproveHours,
};

String _recommendationValue(
  BuildContext context,
  ForecastRecommendationKind kind,
  double value,
) {
  final formatted = NumberFormat(
    '#,##0.##',
    Localizations.localeOf(context).toString(),
  ).format(value);
  return switch (kind) {
    ForecastRecommendationKind.tableTurnover ||
    ForecastRecommendationKind.nonDiningWait ||
    ForecastRecommendationKind.operatingHours =>
      context.l10n.revenueForecastMinutesValue(formatted),
    ForecastRecommendationKind.kitchen ||
    ForecastRecommendationKind.checker ||
    ForecastRecommendationKind.floorService =>
      context.l10n.revenueForecastPerHourValue(formatted),
  };
}

String _bottleneck(BuildContext context, String value) => switch (value) {
  'kitchen' => context.l10n.revenueForecastBottleneckKitchen,
  'checker' => context.l10n.revenueForecastBottleneckChecker,
  'table_turnover' => context.l10n.revenueForecastBottleneckTable,
  'floor_service' => context.l10n.revenueForecastBottleneckFloor,
  'photo_capacity' => context.l10n.revenueForecastBottleneckPhoto,
  'closed' => context.l10n.revenueForecastBottleneckClosed,
  _ => context.l10n.revenueForecastBottleneckDemand,
};

String _dominantBottleneck(RevenueForecastResult result) {
  final counts = <String, int>{};
  for (final day in result.days) {
    if (day.bottleneck == 'closed') continue;
    counts.update(day.bottleneck, (count) => count + 1, ifAbsent: () => 1);
  }
  if (counts.isEmpty) return 'closed';
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}
