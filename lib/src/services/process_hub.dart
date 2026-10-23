import 'dart:async';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';

/// Routes `shell.onStdout`/`onStderr`/`onExit` to the processes the plugin
/// started with `shell.spawn`.
///
/// Lumide can send output before `spawn` returns the pid, so while a spawn
/// is in flight, output for unknown pids is held and replayed once claimed.
class ProcessHub {
  ProcessHub(
    this._shell, {
    this.exitGrace = const Duration(milliseconds: 100),
    bool? isWindows,
  }) : _isWindows = isWindows ?? Platform.isWindows;

  static const _maxHeldEvents = 1000;

  final LumideShell _shell;
  final bool _isWindows;

  /// How long output is still accepted after the exit notification, since
  /// Lumide can report the exit before the last output chunk.
  final Duration exitGrace;

  final Map<int, HostProcess> _processes = {};
  final Map<int, List<_ProcessEvent>> _held = {};
  final List<LumideDisposable> _listeners = [];
  int _spawnsInFlight = 0;
  int _heldEventCount = 0;

  /// Starts [executable] through Lumide.
  Future<HostProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    _listen();
    _spawnsInFlight++;
    try {
      final pid = await _shell.spawn(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
      final process = HostProcess._(pid, _shell, exitGrace, _isWindows);
      _processes[pid] = process;
      for (final event in _held.remove(pid) ?? const <_ProcessEvent>[]) {
        _dispatch(process, event);
      }
      return process;
    } finally {
      _spawnsInFlight--;
      if (_spawnsInFlight == 0) {
        _held.clear();
        _heldEventCount = 0;
      }
    }
  }

  void dispose() {
    for (final listener in _listeners) {
      listener.dispose();
    }
    _listeners.clear();
    _held.clear();
    for (final process in _processes.values.toList()) {
      process._finish(-1);
    }
    _processes.clear();
  }

  void _listen() {
    if (_listeners.isNotEmpty) return;
    _listeners
      ..add(_shell
          .onStdout((pid, data) => _route(pid, _ProcessEvent.stdout(data))))
      ..add(_shell
          .onStderr((pid, data) => _route(pid, _ProcessEvent.stderr(data))))
      ..add(
          _shell.onExit((pid, code) => _route(pid, _ProcessEvent.exit(code))));
  }

  void _route(int pid, _ProcessEvent event) {
    if (_processes[pid] case final process?) {
      _dispatch(process, event);
      return;
    }
    final canHold = _spawnsInFlight > 0 && _heldEventCount < _maxHeldEvents;
    if (!canHold) return;
    _held.putIfAbsent(pid, () => []).add(event);
    _heldEventCount++;
  }

  void _dispatch(HostProcess process, _ProcessEvent event) {
    switch (event.kind) {
      case _ProcessEventKind.stdout:
        process._addStdout(event.data);
      case _ProcessEventKind.stderr:
        process._addStderr(event.data);
      case _ProcessEventKind.exit:
        unawaited(process
            ._exit(event.exitCode)
            .whenComplete(() => _processes.remove(process.pid)));
    }
  }
}

/// A process Lumide started for the plugin.
class HostProcess {
  HostProcess._(this.pid, this._shell, this._exitGrace, this._isWindows);

  final int pid;
  final LumideShell _shell;
  final Duration _exitGrace;
  final bool _isWindows;
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exitCode = Completer<int>();

  Stream<String> get stdout => _stdout.stream;

  Stream<String> get stderr => _stderr.stream;

  Future<int> get exitCode => _exitCode.future;

  bool get hasExited => _exitCode.isCompleted;

  /// Sends [signal] unless the process already exited.
  Future<void> kill([
    LumideProcessSignal signal = LumideProcessSignal.terminate,
  ]) async {
    if (hasExited) return;
    try {
      await _shell.kill(pid, signal: signal);
    } catch (_) {
      // The process already exited or Lumide stopped tracking it.
    }
  }

  /// Asks the process to shut down cleanly, and ends it after [timeout].
  ///
  /// Launcher scripts, such as the `serverpod` script pub installs, do not
  /// pass signals on to the program they start, so when the process is
  /// still running after [escalateAfter], its child processes are
  /// interrupted too. After [timeout] the whole process tree is killed:
  /// the server and its database run below the launcher, and would
  /// otherwise keep their ports. Windows has no interrupt signal, so there
  /// the whole process tree ends at once.
  Future<void> stop({
    Duration escalateAfter = const Duration(seconds: 3),
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (hasExited) return;
    if (_isWindows) {
      await _runQuietly('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }

    await kill(LumideProcessSignal.interrupt);
    if (await _exitsWithin(escalateAfter)) return;
    await _runQuietly('pkill', ['-INT', '-P', '$pid']);
    if (await _exitsWithin(timeout - escalateAfter)) return;

    // Collected before anything dies: an orphaned process moves to a new
    // parent and is no longer found below this one.
    final descendants = await _descendants();
    if (descendants.isNotEmpty) {
      await _runIgnoringErrors('kill', [
        '-KILL',
        for (final descendant in descendants.reversed) '$descendant',
      ]);
    }
    await kill(LumideProcessSignal.kill);
  }

  static const _maxDescendants = 256;

  /// The processes below this one, level by level from its children down.
  Future<List<int>> _descendants() async {
    final found = <int>[];
    var level = [pid];
    while (level.isNotEmpty && found.length < _maxDescendants) {
      final next = <int>[];
      for (final parent in level) {
        next.addAll(await _childrenOf(parent));
      }
      found.addAll(next);
      level = next;
    }
    return found;
  }

  Future<List<int>> _childrenOf(int parent) async {
    try {
      final result = await _shell.run('pgrep', ['-P', '$parent']);
      return [
        for (final line in result.stdout.split('\n'))
          if (int.tryParse(line.trim()) case final child?) child,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _exitsWithin(Duration duration) async {
    try {
      await exitCode.timeout(duration);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _runQuietly(String executable, List<String> arguments) async {
    if (hasExited) return;
    await _runIgnoringErrors(executable, arguments);
  }

  Future<void> _runIgnoringErrors(
    String executable,
    List<String> arguments,
  ) async {
    try {
      await _shell.run(executable, arguments);
    } catch (_) {
      // The process tree already ended, or the tool is missing.
    }
  }

  void _addStdout(String data) {
    if (_stdout.isClosed) return;
    _stdout.add(data);
  }

  void _addStderr(String data) {
    if (_stderr.isClosed) return;
    _stderr.add(data);
  }

  Future<void> _exit(int code) async {
    if (hasExited) return;
    await Future<void>.delayed(_exitGrace);
    _finish(code);
  }

  void _finish(int code) {
    if (hasExited) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(code);
  }
}

enum _ProcessEventKind { stdout, stderr, exit }

class _ProcessEvent {
  const _ProcessEvent.stdout(this.data)
      : kind = _ProcessEventKind.stdout,
        exitCode = 0;

  const _ProcessEvent.stderr(this.data)
      : kind = _ProcessEventKind.stderr,
        exitCode = 0;

  const _ProcessEvent.exit(this.exitCode)
      : kind = _ProcessEventKind.exit,
        data = '';

  final _ProcessEventKind kind;
  final String data;
  final int exitCode;
}
