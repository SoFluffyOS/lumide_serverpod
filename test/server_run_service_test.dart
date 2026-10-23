import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

void main() {
  late FakeHost host;
  late ProcessHub processHub;
  late ServerRunService runService;

  setUp(() async {
    host = FakeHost();
    processHub = ProcessHub(
      host.shell,
      exitGrace: Duration.zero,
      isWindows: false,
    );
    final logService = LogService((_) {});
    final projectService = ProjectService(host);
    await projectService.refresh();
    runService = ServerRunService(
      host,
      projectService,
      CliService(host, processHub, logService),
      processHub,
      logService,
    );
  });

  tearDown(() => processHub.dispose());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('starts a server once when launched twice at the same time', () async {
    host.shell.spawnGate = Completer<void>();
    final first = runService.start();
    final second = runService.start();
    await settle();
    host.shell.spawnGate?.complete();
    await Future.wait([first, second]);

    expect(host.shell.spawned, hasLength(1));
    expect(runService.runningServers, ['app_server']);
    expect(host.window.messages, ['app_server is already running.']);
  });

  test('stops a server that was asked to stop while starting', () async {
    host.shell.spawnGate = Completer<void>();
    final launch = runService.start();
    await settle();
    final stop = runService.stop();
    await settle();
    host.shell.spawnGate?.complete();
    await settle();

    expect(host.shell.signals.first.$2, LumideProcessSignal.interrupt);
    host.shell.emitExit(host.shell.signals.first.$1, 0);
    await Future.wait([launch, stop]);
    await settle();
    expect(runService.runningServers, isEmpty);
  });

  test('watches the server even when Lumide fails to hear it started',
      () async {
    host.launch.failDidStart = true;
    await runService.start();
    host.shell
      ..emitStdout(100, 'Server running.\n')
      ..emitExit(100, 0);
    await settle();

    expect(runService.runningServers, isEmpty);
    expect(host.launch.ended.single.exitCode, 0);
    expect(host.window.channels.single.text.toString(),
        contains('Server running.'));
  });

  test('reports the end of a server whose output channel is gone', () async {
    await runService.start();
    host.window.channels.single.closed = true;
    host.shell
      ..emitStdout(100, 'lost\n')
      ..emitExit(100, 1);
    await settle();

    expect(runService.runningServers, isEmpty);
    expect(host.launch.ended.single.exitCode, 1);
  });

  test('turns launches away once disposed', () async {
    await runService.dispose();
    await runService.start();

    expect(host.shell.spawned, isEmpty);
  });

  test('the status item stays gone once disposed', () async {
    final statusBar = StatusBarService(host);
    await statusBar.update(version: null, runningServers: const []);
    await statusBar.dispose();
    await statusBar.update(version: null, runningServers: const ['late']);

    expect(host.statusBar.items, isEmpty);
  });
}
