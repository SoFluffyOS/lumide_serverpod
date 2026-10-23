import 'dart:async';

import 'package:lumide_api/lumide_api.dart';

/// A Lumide host with one Serverpod server at [serverRoot], answering the
/// calls the plugin's services make.
class FakeHost implements LumideContext {
  FakeHost({this.serverRoot = '/work/app/app_server'});

  final String serverRoot;

  @override
  late final FakeShell shell = FakeShell();
  @override
  late final FakeWindow window = FakeWindow();
  @override
  late final FakeLaunch launch = FakeLaunch();
  @override
  late final FakeWorkspace workspace = FakeWorkspace(this);
  @override
  late final FakeFileSystem fs = FakeFileSystem(this);
  @override
  late final FakeDebug debug = FakeDebug();
  @override
  late final FakeEditor editor = FakeEditor();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeShell implements LumideShell {
  int _nextPid = 100;
  final spawned = <List<String>>[];
  final signals = <(int, LumideProcessSignal?)>[];
  final ran = <List<String>>[];

  /// When set, spawns wait for it.
  Completer<void>? spawnGate;
  String versionOutput = 'Serverpod version: 4.0.4';
  final _stdout = <void Function(int, String)>[];
  final _stderr = <void Function(int, String)>[];
  final _exit = <void Function(int, int)>[];

  void emitStdout(int pid, String data) {
    for (final listener in List.of(_stdout)) {
      listener(pid, data);
    }
  }

  void emitExit(int pid, int code) {
    for (final listener in List.of(_exit)) {
      listener(pid, code);
    }
  }

  @override
  Future<ProcessResult> run(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    ran.add([command, ...arguments]);
    if (arguments case ['version']) {
      return ProcessResult(exitCode: 0, stdout: versionOutput, stderr: '');
    }
    return const ProcessResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<int> spawn(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    spawned.add([command, ...arguments]);
    await spawnGate?.future;
    return _nextPid++;
  }

  @override
  Future<bool> kill(int pid, {LumideProcessSignal? signal}) async {
    signals.add((pid, signal));
    return true;
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

class FakeWindow implements LumideWindow {
  final messages = <String>[];
  final channels = <FakeOutput>[];

  @override
  Future<void> showMessage(
    String message, {
    MessageType type = MessageType.info,
    String? title,
  }) async =>
      messages.add(message);

  @override
  Future<LumideOutputChannel> createOutputChannel(
    String name, {
    int? maxEntries,
  }) async {
    final channel = FakeOutput(name);
    channels.add(channel);
    return channel;
  }

  @override
  Future<QuickPickItem?> showQuickPick(
    List<QuickPickItem> items, {
    String? placeholder,
    bool matchOnDescription = true,
    bool matchOnDetail = true,
    Map<String, int>? position,
  }) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeOutput implements LumideOutputChannel {
  FakeOutput(this.name);

  final String name;
  final text = StringBuffer();
  int appends = 0;

  /// When set, appends fail like a channel Lumide closed.
  bool closed = false;

  @override
  String get id => name;

  @override
  Future<void> append(String value) async {
    appends++;
    if (closed) throw StateError('closed');
    text.write(value);
  }

  @override
  Future<void> appendLine(String value) => append('$value\n');

  @override
  Future<void> appendLog(LumideLogRecord record) => appendLine(record.message);

  @override
  Future<void> clear() async => text.clear();

  @override
  Future<void> show({bool preserveFocus = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeLaunch implements LumideLaunch {
  final started = <LumideLaunchEvent>[];
  final ended = <LumideLaunchEvent>[];
  bool failDidStart = false;

  @override
  Future<void> didStart(LumideLaunchEvent event) async {
    if (failDidStart) throw StateError('host went away');
    started.add(event);
  }

  @override
  Future<void> didEnd(LumideLaunchEvent event) async => ended.add(event);

  @override
  Future<void> updateConfigurations(
    String providerId,
    List<LumideLaunchConfiguration> configurations,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeWorkspace implements LumideWorkspace {
  FakeWorkspace(this._host);

  final FakeHost _host;

  @override
  Future<List<String>> findFiles(
    String glob, {
    int? maxResults,
    String? folder,
  }) async =>
      [Uri.file('${_host.serverRoot}/pubspec.yaml').toString()];

  @override
  Future<Object?> getConfiguration(String section, {String? scope}) async =>
      null;

  @override
  Future<LumideWorkspaceFolder?> getWorkspaceFolder(String uri) async => null;

  @override
  Future<String?> getRootUri() async => '/work/app';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeFileSystem implements LumideFileSystem {
  FakeFileSystem(this._host);

  final FakeHost _host;

  @override
  Future<String> readString(String path) async {
    if (path == '${_host.serverRoot}/pubspec.yaml') {
      return 'name: app_server\ndependencies:\n  serverpod: 4.0.4\n';
    }
    throw StateError('No file $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDebug implements LumideDebug {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeEditor implements LumideEditor {
  @override
  Future<String?> getActiveDocumentUri() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
