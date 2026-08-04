import 'dart:io';

/// Returns the generic production-gate implementation plus the repository
/// paths that the convention resolver can discover.
String readProductionGateContract() {
  final discoverablePaths = <String>[];
  for (final directoryPath in ['scripts', 'supabase/migrations']) {
    discoverablePaths.addAll(
      Directory(
        directoryPath,
      ).listSync().whereType<File>().map((file) => file.path),
    );
  }
  discoverablePaths.sort();

  return [
    File('scripts/deploy_pos_production.sh').readAsStringSync(),
    File('scripts/lib/production_migration_gate.sh').readAsStringSync(),
    ...discoverablePaths,
  ].join('\n');
}
