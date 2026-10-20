import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/terminal_auth.dart';
import 'package:globos_pos_system/core/auth/terminal_auth_native.dart';

void main() {
  test(
    'three Windows terminal files persist and remove independently',
    () async {
      final root = await Directory.systemTemp.createTemp('globos-auth-test-');
      addTearDown(() => root.delete(recursive: true));
      final storage = {
        for (final terminal in terminalNames)
          terminal: NativeTerminalStorage(Directory('${root.path}/$terminal')),
      };
      for (final entry in storage.entries) {
        await TerminalSessionStorage(entry.value).initialize();
        await TerminalSessionStorage(
          entry.value,
        ).persistSession('fixture-${entry.key}');
        await TerminalPkceStorage(
          entry.value,
          entry.key,
        ).setItem(key: 'verifier', value: 'pkce-${entry.key}');
      }
      // A new process/storage object recovers only its own terminal.
      for (final terminal in terminalNames) {
        final reopened = NativeTerminalStorage(
          Directory('${root.path}/$terminal'),
        );
        expect(
          await TerminalSessionStorage(reopened).accessToken(),
          'fixture-$terminal',
        );
        expect(
          await TerminalPkceStorage(
            reopened,
            terminal,
          ).getItem(key: 'verifier'),
          'pkce-$terminal',
        );
      }
      await TerminalSessionStorage(
        storage['cashier']!,
      ).removePersistedSession();
      expect(
        await TerminalSessionStorage(storage['cashier']!).hasAccessToken(),
        false,
      );
      for (final terminal in ['print_station', 'customer_display']) {
        expect(
          await TerminalSessionStorage(storage[terminal]!).accessToken(),
          'fixture-$terminal',
        );
      }
      // Replacement writes remain readable; a queued logout wins over a refresh.
      final station = TerminalSessionStorage(storage['print_station']!);
      await station.persistSession('refreshed-fixture');
      expect(await station.accessToken(), 'refreshed-fixture');
      await Future.wait([
        station.persistSession('next-fixture'),
        station.removePersistedSession(),
      ]);
      expect(await station.accessToken(), isNull);
    },
  );

  test('only supported terminal arguments choose persistent login spaces', () {
    for (final name in terminalNames) {
      expect(terminalFromArgs(['--terminal=$name']), name);
    }
    expect(terminalFromArgs([]), isNull);
    expect(
      () => terminalFromArgs(['--terminal=../../other']),
      throwsArgumentError,
    );
    expect(
      terminalNames
          .map((n) => terminalNamespace('https://fixture.invalid', n))
          .toSet(),
      hasLength(terminalNames.length),
    );
  });
}
