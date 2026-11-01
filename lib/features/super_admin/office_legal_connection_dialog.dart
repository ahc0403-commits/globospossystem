import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/terminal_auth.dart';
import '../../core/constants/app_constants.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/services/pos_backend.dart';
import 'super_admin_provider.dart';

typedef OfficeConnectionRpc =
    Future<dynamic> Function(String name, Map<String, dynamic> params);

class OfficeConnectionCode {
  const OfficeConnectionCode(this.operationId, this.proof);
  factory OfficeConnectionCode.create() {
    final random = Random.secure();
    return OfficeConnectionCode(
      const Uuid().v4(),
      base64Url.encode(List.generate(48, (_) => random.nextInt(256))),
    );
  }
  final String operationId;
  final String proof;
  String encode() =>
      'GLOBOS-POS-1.${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'operationId': operationId, 'proof': proof})))}';
  factory OfficeConnectionCode.decode(String input) {
    if (!input.startsWith('GLOBOS-POS-1.') || input.length > 1024) {
      throw const FormatException('Invalid pairing code');
    }
    final row =
        jsonDecode(
              utf8.decode(
                base64Url.decode(base64Url.normalize(input.substring(13))),
              ),
            )
            as Map;
    final id = row['operationId'], proof = row['proof'];
    if (row['version'] != 1 ||
        id is! String ||
        !Uuid.isValidUUID(fromString: id) ||
        proof is! String ||
        proof.length < 32 ||
        proof.length > 128) {
      throw const FormatException('Invalid pairing code');
    }
    return OfficeConnectionCode(id, proof);
  }
}

class OfficeLegalConnectionDialog extends StatefulWidget {
  const OfficeLegalConnectionDialog({
    super.key,
    required this.entities,
    required this.actorId,
    this.rpc,
  });
  final List<SuperTaxEntity> entities;
  final String actorId;
  final OfficeConnectionRpc? rpc;
  @override
  State<OfficeLegalConnectionDialog> createState() =>
      _OfficeLegalConnectionDialogState();
}

class _OfficeLegalConnectionDialogState
    extends State<OfficeLegalConnectionDialog> {
  String? _entity;
  OfficeConnectionCode? _code;
  Map<String, dynamic>? _result;
  bool _busy = false, _failed = false;
  int _generation = 0;
  List<SuperTaxEntity> get _entities =>
      widget.entities.where((e) => e.isInternal).toList();
  bool get _sameActor =>
      widget.rpc != null || supabase.auth.currentUser?.id == widget.actorId;
  String get _key => 'office-legal-connection-v1:${widget.actorId}:$_entity';

  Future<dynamic> _call(String name, Map<String, dynamic> params) =>
      widget.rpc?.call(name, params) ?? supabase.rpc(name, params: params);
  Future<String?> _read() async => TerminalAuth.current != null
      ? TerminalAuth.current!.storage.read(_key)
      : (await SharedPreferences.getInstance()).getString(_key);
  Future<void> _write(String value) async {
    if (TerminalAuth.current != null) {
      await TerminalAuth.current!.storage.write(_key, value);
    } else {
      await (await SharedPreferences.getInstance()).setString(_key, value);
    }
  }

  Future<void> _clearCompletedCode() async {
    try {
      if(TerminalAuth.current!=null) {await TerminalAuth.current!.storage.remove(_key);}
      else {await (await SharedPreferences.getInstance()).remove(_key);}
    } catch (_) {
      // Cleanup failure does not change the confirmed server result.
    }
  }

  @override
  void initState() {
    super.initState();
    _entity = _entities.firstOrNull?.id;
    if (_entity != null) _restore();
  }

  Future<void> _restore() async {
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final raw = await _read();
      final code = raw == null ? null : OfficeConnectionCode.decode(raw);
      final result = await _call('get_office_legal_connection_for_entity_v1', {
        'p_tax_entity_id': _entity,
      });
      if (!mounted || generation != _generation || !_sameActor) return;
      setState(() {
        _result = result is Map ? Map<String, dynamic>.from(result) : null;
        _code =
            code != null &&
                (result == null || code.operationId == _result?['operation_id'])
            ? code
            : null;
        _failed = false;
      });
      if(_result?['state']=='confirmed') {await _clearCompletedCode();}
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    if (_busy || _entity == null || !_sameActor) return;
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      if (_code != null && _result?['state'] != 'expired') {
        try {
          final previous = await _call('get_office_legal_connection_v1', {
            'p_operation_id': _code!.operationId,
          });
          if (!mounted || generation != _generation || !_sameActor) return;
          setState(() {
            _result = Map<String, dynamic>.from(previous as Map);
            _failed = false;
          });
          return;
        } on PostgrestException catch (error) {
          if (!error.message.contains(
            'POS_OFFICE_LEGAL_CONNECTION_NOT_FOUND',
          )) {
            rethrow;
          }
        }
      }
      final code = _result?['state'] == 'expired' || _code == null
          ? OfficeConnectionCode.create()
          : _code!;
      // Persist the retry identity before sending the command. This is a
      // pairing challenge, never an Office/POS Auth token or server API secret.
      await _write(code.encode());
      _code = code;
      if (!_sameActor) return;
      final result = await _call('begin_office_legal_connection_v1', {
        'p_operation_id': code.operationId,
        'p_tax_entity_id': _entity,
        'p_proof': code.proof,
      });
      if (!mounted || generation != _generation || !_sameActor) return;
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _failed = false;
      });
      if(_result?['state']=='confirmed') {await _clearCompletedCode();}
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy || _result == null || !_sameActor) return;
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final result = await _call('get_office_legal_connection_v1', {
        'p_operation_id': _result!['operation_id'],
      });
      if (!mounted || generation != _generation || !_sameActor) return;
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _failed = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = _result?['state'];
    final status = switch (state) {
      'confirmed' => l.resilienceOfficeConfirmed,
      'expired' => l.resilienceOfficeExpired,
      'requires_review' => l.resilienceOfficeReview,
      _ => l.resilienceOfficeAwaiting,
    };
    return AlertDialog(
      title: Text(l.resilienceOfficeLink),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.resilienceOfficeInstructions),
              const SizedBox(height: 16),
              if (_entities.isEmpty)
                Text(l.resilienceOfficeInternalOnly)
              else
                DropdownButtonFormField<String>(
                  initialValue: _entity,
                  decoration: InputDecoration(
                    labelText: l.superAdminLegalEntity,
                  ),
                  items: [
                    for (final entity in _entities)
                      DropdownMenuItem(
                        value: entity.id,
                        child: Text(entity.name),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (id) {
                          setState(() {
                            _entity = id;
                            _code = null;
                            _result = null;
                          });
                          _restore();
                        },
                ),
              if (_result != null) ...[
                const SizedBox(height: 12),
                Text(status, key: const Key('office_connection_status')),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_failed) Text(l.resilienceOfficeFailed),
              if (_code != null && state == 'awaiting_office') ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _code!.encode())),
                  icon: const Icon(Icons.copy),
                  label: Text(l.resilienceOfficeCopyCode),
                ),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(AppConstants.officeSystemUrl).replace(
                      path: '/system/settings',
                      query: null,
                      fragment: null,
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l.resilienceOfficeOpen),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l.close),
        ),
        if (_result != null)
          TextButton(
            onPressed: _busy ? null : _refresh,
            child: Text(l.refresh),
          ),
        if (state != 'confirmed' &&
            state != 'requires_review' &&
            _entities.isNotEmpty)
          FilledButton(
            onPressed: _busy ? null : _prepare,
            child: Text(l.resilienceOfficePrepare),
          ),
      ],
    );
  }
}
