import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

void main() {
  late FakeHost host;

  setUp(() => host = FakeHost());

  CliService cli({Duration recheck = Duration.zero}) => CliService(
        host,
        ProcessHub(host.shell, isWindows: false),
        LogService((_) {}),
        missingCliRecheck: recheck,
      );

  test('finds a CLI installed after it was missing', () async {
    final service = cli();
    final changes = <String>[];
    service.onDidChangeVersion = (version) => changes.add('$version');
    host.shell.versionOutput = 'zsh: command not found: serverpod';

    expect(await service.version(), isNull);
    host.shell.versionOutput = 'Serverpod version: 4.0.4';

    expect((await service.version()).toString(), '4.0.4');
    expect(changes, ['4.0.4']);
  });

  test('remembers an installed CLI', () async {
    final service = cli();

    await service.version();
    await service.version();

    expect(host.shell.ran, hasLength(1));
  });

  test('remembers a missing CLI until the recheck is due', () async {
    final service = cli(recheck: const Duration(hours: 1));
    host.shell.versionOutput = '';

    await service.version();
    await service.version();

    expect(host.shell.ran, hasLength(1));
  });

  test('opens the output channel again after it failed to open', () async {
    final service = cli();
    host.window.failingChannels = 1;

    await expectLater(service.channel(), throwsStateError);
    expect((await service.channel()).id, 'Serverpod');
  });
}
