import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

/// Stops a `serverpod start` that runs a server outside Lumide, such as one
/// left running by an earlier Lumide session.
///
/// `serverpod start` compiles the server to `.dart_tool/serverpod/server.dill`
/// and runs it, together with its compiler, as children of the CLI. Those
/// processes are found by that path; their parent, the CLI, is interrupted
/// and stops the rest.
class OtherInstance {
  OtherInstance(
    this._shell, {
    this.pollInterval = const Duration(milliseconds: 500),
    this.timeout = const Duration(seconds: 20),
  });

  final LumideShell _shell;
  final Duration pollInterval;
  final Duration timeout;

  /// The line `serverpod start` prints when it finds another instance.
  static const marker = 'is already running (MCP socket';

  /// Stops the instance running [serverRoot]. True when none runs anymore.
  Future<bool> stop(String serverRoot) async {
    final processes = await _serverProcesses(serverRoot);
    if (processes.isEmpty) return true;

    final targets = await _clisOf(processes);
    await _run('kill', ['-INT', for (final target in targets) '$target']);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if ((await _serverProcesses(serverRoot)).isEmpty) return true;
    }
    return false;
  }

  Future<List<int>> _serverProcesses(String serverRoot) async {
    final program =
        path.join(serverRoot, '.dart_tool', 'serverpod', 'server.dill');
    final result = await _run('pgrep', ['-f', escapeRegExp(program)]);
    return _pids(result?.stdout ?? '');
  }

  /// The CLI each of [processes] runs under, or the process itself once
  /// the CLI is gone.
  Future<Set<int>> _clisOf(List<int> processes) async {
    final result = await _run('ps', [
      '-o',
      'pid=,ppid=',
      '-p',
      processes.join(','),
    ]);
    final targets = <int>{};
    for (final line in (result?.stdout ?? '').split('\n')) {
      if (_pids(line) case [final pid, final parent]) {
        final cliAlive = parent > 1 && !processes.contains(parent);
        targets.add(switch (cliAlive) {
          true => parent,
          false => pid,
        });
      }
    }
    return targets;
  }

  Future<ProcessResult?> _run(String executable, List<String> arguments) async {
    try {
      return await _shell.run(executable, arguments);
    } catch (_) {
      return null;
    }
  }

  static List<int> _pids(String text) => [
        for (final word in text.split(RegExp(r'\s+')))
          if (int.tryParse(word) case final pid?) pid,
      ];

  /// [text] as a regular expression matching itself.
  static String escapeRegExp(String text) => text.replaceAllMapped(
        RegExp(r'[.*+?^${}()|[\]\\]'),
        (match) => '\\${match[0]}',
      );
}
