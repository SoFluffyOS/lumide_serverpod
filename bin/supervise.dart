/// Runs a server for the Serverpod plugin, and stops it when Lumide goes
/// away.
///
/// Usage: `dart supervise.dart <executable> [arguments...]`
///
/// Lumide holds this process's stdin open while it runs. However Lumide
/// ends (quitting, crashing or being force quit), the system closes that
/// pipe, and the server is stopped as Ctrl+C would stop it in a terminal.
/// SIGINT and SIGTERM stop it the same way.
///
/// Uses `dart:io` only, so it runs on its own, without the plugin's
/// packages.
library;

import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart supervise.dart <executable> [arguments...]');
    exit(64);
  }

  final Process server;
  try {
    server = await Process.start(
      arguments.first,
      arguments.sublist(1),
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    stderr.writeln(error.message);
    exit(127);
  }
  unawaited(server.stdin.close());
  final forwarding = Future.wait([
    stdout.addStream(server.stdout),
    stderr.addStream(server.stderr),
  ]);

  final supervisor = _Supervisor(server);
  ProcessSignal.sigint.watch().listen((_) => supervisor.stop());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => supervisor.stop());
  }
  stdin.listen((_) {}, onDone: supervisor.stop, onError: (_) {});

  final exitCode = await server.exitCode;
  await forwarding;
  exit(exitCode);
}

/// Stops the server the way a terminal would: an interrupt first, then the
/// whole process tree when it does not end.
class _Supervisor {
  _Supervisor(this._server);

  final Process _server;
  bool _stopping = false;

  /// Launcher scripts, such as the `serverpod` script pub installs, do not
  /// pass signals on, so their children are interrupted after this long.
  static const _escalateAfter = Duration(seconds: 3);
  static const _timeout = Duration(seconds: 15);

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;

    if (Platform.isWindows) {
      await _run('taskkill', ['/PID', '${_server.pid}', '/T', '/F']);
      return;
    }

    _server.kill(ProcessSignal.sigint);
    if (await _exitsWithin(_escalateAfter)) return;
    for (final child in await _childrenOf(_server.pid)) {
      Process.killPid(child, ProcessSignal.sigint);
    }
    if (await _exitsWithin(_timeout - _escalateAfter)) return;

    // Collected before anything dies: an orphaned process moves to a new
    // parent and is no longer found below this one.
    final tree = await _descendantsOf(_server.pid);
    for (final process in tree.reversed) {
      Process.killPid(process, ProcessSignal.sigkill);
    }
    _server.kill(ProcessSignal.sigkill);
  }

  Future<bool> _exitsWithin(Duration duration) async {
    try {
      await _server.exitCode.timeout(duration);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  static Future<List<int>> _descendantsOf(int root) async {
    final found = <int>[];
    var level = [root];
    while (level.isNotEmpty && found.length < 256) {
      final next = <int>[];
      for (final parent in level) {
        next.addAll(await _childrenOf(parent));
      }
      found.addAll(next);
      level = next;
    }
    return found;
  }

  static Future<List<int>> _childrenOf(int parent) async {
    final result = await _run('pgrep', ['-P', '$parent']);
    return [
      for (final line in '${result?.stdout ?? ''}'.split('\n'))
        if (int.tryParse(line.trim()) case final child?) child,
    ];
  }

  static Future<ProcessResult?> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(executable, arguments);
    } on ProcessException {
      return null;
    }
  }
}
