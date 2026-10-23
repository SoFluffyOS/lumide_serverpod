import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

void main() {
  late _FakeShell shell;
  late ProcessHub hub;

  setUp(() {
    shell = _FakeShell();
    hub = ProcessHub(shell, exitGrace: Duration.zero, isWindows: false);
  });

  tearDown(() => hub.dispose());

  test('routes output and the exit code to the process', () async {
    shell.nextPid = 7;
    final process = await hub.spawn('serverpod', ['generate']);
    final output = process.stdout.join();
    final errors = process.stderr.join();

    shell
      ..emitStdout(7, 'Generating code\n')
      ..emitStdout(8, 'another process\n')
      ..emitStderr(7, 'warning\n')
      ..emitExit(7, 0);

    expect(await process.exitCode, 0);
    expect(await output, 'Generating code\n');
    expect(await errors, 'warning\n');
  });

  test('replays output sent before spawn returned the pid', () async {
    shell
      ..nextPid = 9
      ..onSpawn = () {
        shell
          ..emitStdout(9, 'early\n')
          ..emitExit(9, 3);
      };

    final process = await hub.spawn('dart', ['bin/main.dart']);

    expect(await process.stdout.join(), 'early\n');
    expect(await process.exitCode, 3);
  });

  test('kill sends the signal until the process exits', () async {
    shell.nextPid = 4;
    final process = await hub.spawn('serverpod', ['start']);

    await process.kill(LumideProcessSignal.interrupt);
    shell.emitExit(4, 130);
    await process.exitCode;
    await process.kill();

    expect(shell.signals, [LumideProcessSignal.interrupt]);
  });

  group('stop', () {
    const escalateAfter = Duration(milliseconds: 20);
    const timeout = Duration(milliseconds: 60);

    test('interrupts the process and waits for it to exit', () async {
      shell
        ..nextPid = 5
        ..onKill = (pid) => shell.emitExit(pid, 0);
      final process = await hub.spawn('serverpod', ['start']);

      await process.stop(escalateAfter: escalateAfter, timeout: timeout);

      expect(shell.signals, [LumideProcessSignal.interrupt]);
      expect(shell.commands, isEmpty);
    });

    test('interrupts the children of a launcher script', () async {
      shell
        ..nextPid = 6
        ..onRun = (command) {
          if (command.contains('-INT')) shell.emitExit(6, 0);
        };
      final process = await hub.spawn('serverpod', ['start']);

      await process.stop(escalateAfter: escalateAfter, timeout: timeout);

      expect(shell.signals, [LumideProcessSignal.interrupt]);
      expect(shell.commands, [
        ['pkill', '-INT', '-P', '6'],
      ]);
    });

    test('kills the whole process tree, leaves first, when it keeps running',
        () async {
      shell
        ..nextPid = 7
        ..children[7] = [8]
        ..children[8] = [9, 10];
      final process = await hub.spawn('serverpod', ['start']);

      await process.stop(escalateAfter: escalateAfter, timeout: timeout);

      expect(shell.signals, [
        LumideProcessSignal.interrupt,
        LumideProcessSignal.kill,
      ]);
      expect(shell.commands, [
        ['pkill', '-INT', '-P', '7'],
        ['pgrep', '-P', '7'],
        ['pgrep', '-P', '8'],
        ['pgrep', '-P', '9'],
        ['pgrep', '-P', '10'],
        ['kill', '-KILL', '10', '9', '8'],
      ]);
    });

    test('ends the process tree on Windows', () async {
      final windowsHub = ProcessHub(
        shell,
        exitGrace: Duration.zero,
        isWindows: true,
      );
      addTearDown(windowsHub.dispose);
      shell.nextPid = 8;
      final process = await windowsHub.spawn('serverpod', ['start']);

      await process.stop(escalateAfter: escalateAfter, timeout: timeout);

      expect(shell.signals, isEmpty);
      expect(shell.commands, [
        ['taskkill', '/PID', '8', '/T', '/F'],
      ]);
    });
  });
}

class _FakeShell implements LumideShell {
  int nextPid = 1;
  void Function()? onSpawn;
  void Function(int pid)? onKill;
  void Function(List<String> command)? onRun;
  final signals = <LumideProcessSignal?>[];
  final commands = <List<String>>[];

  /// Child pids by parent, as `pgrep -P` prints them.
  final children = <int, List<int>>{};
  final _stdout = <void Function(int, String)>[];
  final _stderr = <void Function(int, String)>[];
  final _exit = <void Function(int, int)>[];

  void emitStdout(int pid, String data) {
    for (final listener in _stdout) {
      listener(pid, data);
    }
  }

  void emitStderr(int pid, String data) {
    for (final listener in _stderr) {
      listener(pid, data);
    }
  }

  void emitExit(int pid, int exitCode) {
    for (final listener in _exit) {
      listener(pid, exitCode);
    }
  }

  @override
  Future<int> spawn(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    onSpawn?.call();
    return nextPid;
  }

  @override
  Future<bool> kill(int pid, {LumideProcessSignal? signal}) async {
    signals.add(signal);
    onKill?.call(pid);
    return true;
  }

  @override
  Future<ProcessResult> run(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    final commandLine = [command, ...arguments];
    commands.add(commandLine);
    onRun?.call(commandLine);
    if (commandLine case ['pgrep', '-P', final parent]) {
      final pids = children[int.parse(parent)] ?? const [];
      return ProcessResult(exitCode: 0, stdout: pids.join('\n'), stderr: '');
    }
    return const ProcessResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  LumideDisposable onStdout(void Function(int pid, String data) callback) =>
      _listen(_stdout, callback);

  @override
  LumideDisposable onStderr(void Function(int pid, String data) callback) =>
      _listen(_stderr, callback);

  @override
  LumideDisposable onExit(void Function(int pid, int exitCode) callback) =>
      _listen(_exit, callback);

  LumideDisposable _listen<T>(List<T> listeners, T callback) {
    listeners.add(callback);
    return LumideDisposable(() => listeners.remove(callback));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
