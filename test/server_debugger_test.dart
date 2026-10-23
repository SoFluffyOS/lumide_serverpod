import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

const _fileUri = 'file:///app/app_server/lib/src/greeting_endpoint.dart';
const _packageUri = 'package:app_server/src/greeting_endpoint.dart';

void main() {
  late _FakeDebug debug;
  late _FakeOutput output;
  late List<_FakeVm> vms;
  late ServerDebugger debugger;

  setUp(() {
    debug = _FakeDebug();
    output = _FakeOutput();
    vms = [];
    debugger = ServerDebugger(
      context: _FakeContext(debug),
      sessionId: 'session',
      name: 'app_server',
      serverRoot: '/app/app_server',
      output: output,
      logService: LogService((_) {}),
      reconnectDelay: Duration.zero,
      connect: (_) async {
        final vm = _FakeVm();
        vms.add(vm);
        return vm.service;
      },
    );
  });

  tearDown(() => debugger.end());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('installs breakpoints by package URI and reports them verified',
      () async {
    await debugger.start();
    await debugger.attach('ws://vm');
    await debugger.setBreakpoints(
      const [LumideDebugBreakpoint(sourceUri: _fileUri, line: 12)],
    );
    await settle();

    expect(vms.single.breakpointUris, [_packageUri]);
    expect(debug.breakpoints.single.verified, isTrue);
    expect(debug.states.last, LumideDebugSessionState.running);
  });

  test('reconnects and installs breakpoints again when the VM goes away',
      () async {
    await debugger.attach('ws://vm');
    await debugger.setBreakpoints(
      const [LumideDebugBreakpoint(sourceUri: _fileUri, line: 12)],
    );
    await settle();

    await vms.single.close();
    await settle();

    expect(vms, hasLength(2));
    expect(vms.last.breakpointUris, [_packageUri]);
    expect(debug.breakpoints.single.verified, isTrue);
  });

  test('resumes when a breakpoint condition is false', () async {
    await debugger.attach('ws://vm');
    await debugger.setBreakpoints(
      const [
        LumideDebugBreakpoint(
          sourceUri: _fileUri,
          line: 12,
          condition: 'name == "nobody"',
        ),
      ],
    );
    await settle();

    vms.single
      ..conditionResult = false
      ..pauseOnBreakpoint();
    await settle();

    expect(vms.single.resumes, 1);
    expect(debug.states, isNot(contains(LumideDebugSessionState.paused)));
  });

  test('pauses on a breakpoint without a condition', () async {
    await debugger.attach('ws://vm');
    await debugger.setBreakpoints(
      const [LumideDebugBreakpoint(sourceUri: _fileUri, line: 12)],
    );
    await settle();

    vms.single.pauseOnBreakpoint();
    await settle();

    expect(vms.single.resumes, 0);
    expect(debug.states.last, LumideDebugSessionState.paused);
    expect(debug.reason, 'breakpoint');
  });

  test('installs a breakpoint once when Lumide sends it twice at once',
      () async {
    await debugger.attach('ws://vm');
    const breakpoints = [
      LumideDebugBreakpoint(sourceUri: _fileUri, line: 12),
    ];
    await Future.wait([
      debugger.setBreakpoints(breakpoints),
      debugger.setBreakpoints(breakpoints),
    ]);
    await settle();

    expect(vms.single.breakpointUris, [_packageUri]);
  });

  test('lets go of a server that stopped answering', () async {
    final releasing = ServerDebugger(
      context: _FakeContext(debug),
      sessionId: 'session',
      name: 'app_server',
      serverRoot: '/app/app_server',
      output: output,
      logService: LogService((_) {}),
      releaseTimeout: const Duration(milliseconds: 50),
      connect: (_) async {
        final vm = _FakeVm();
        vms.add(vm);
        return vm.service;
      },
    );
    addTearDown(releasing.end);
    await releasing.attach('ws://vm');
    await settle();
    vms.single.unresponsive = true;

    await releasing.release().timeout(const Duration(seconds: 1));
  });

  test('keeps debugging the main isolate when another one pauses', () async {
    await debugger.attach('ws://vm');
    await debugger.setBreakpoints(
      const [LumideDebugBreakpoint(sourceUri: _fileUri, line: 12)],
    );
    await settle();

    vms.single.pauseOtherIsolate();
    await settle();
    vms.single.pauseOnBreakpoint();
    await settle();

    expect(debug.states.last, LumideDebugSessionState.paused);
    expect(debug.reason, 'breakpoint');
    expect(vms.single.breakpointUris, [_packageUri]);
  });

  test('a server waiting at its start resumes once breakpoints are in',
      () async {
    final waiting = ServerDebugger(
      context: _FakeContext(debug),
      sessionId: 'session',
      name: 'app_server',
      serverRoot: '/app/app_server',
      output: output,
      logService: LogService((_) {}),
      pausesOnStart: true,
      connect: (_) async {
        final vm = _FakeVm(pausedAtStart: true);
        vms.add(vm);
        return vm.service;
      },
    );
    addTearDown(waiting.end);

    await waiting.attach('ws://vm');
    await settle();
    expect(vms.single.resumes, 0);

    await waiting.setBreakpoints(
      const [LumideDebugBreakpoint(sourceUri: _fileUri, line: 12)],
    );
    await settle();

    expect(vms.single.breakpointUris, [_packageUri]);
    expect(vms.single.resumes, 1);

    vms.single.startOtherIsolate();
    await settle();

    expect(vms.single.resumedIsolates, ['isolates/1', 'isolates/2']);
    expect(debug.states, isNot(contains(LumideDebugSessionState.paused)));
  });
}

/// A VM service with one isolate that answers what the debugger asks.
class _FakeVm {
  _FakeVm({bool pausedAtStart = false}) : _pausedAtStart = pausedAtStart {
    service = VmService(_incoming.stream, _handle);
  }

  final _incoming = StreamController<String>();
  late final VmService service;
  final bool _pausedAtStart;
  final breakpointUris = <String>[];
  final resumedIsolates = <String>[];
  int get resumes => resumedIsolates.length;
  bool conditionResult = true;

  /// When set, the VM stops answering requests, like a wedged server.
  bool unresponsive = false;

  Future<void> close() async {
    await service.dispose();
    await _incoming.close();
  }

  void pauseOnBreakpoint() {
    _event('Debug', {
      'type': 'Event',
      'kind': 'PauseBreakpoint',
      'isolate': _isolateRef,
      'timestamp': 0,
      'pauseBreakpoints': [_breakpoint],
      'topFrame': {'type': 'Frame', 'index': 0},
    });
  }

  void _handle(String message) {
    if (unresponsive) return;
    final request = jsonDecode(message) as Map<String, dynamic>;
    final method = request['method'] as String;
    final params = request['params'] as Map<String, dynamic>? ?? const {};
    final result = switch (method) {
      'getVM' => {
          'type': 'VM',
          'name': 'vm',
          'isolates': [_isolateRef],
        },
      'getIsolate' => {
          ..._isolateRef,
          'type': 'Isolate',
          'pauseEvent': {
            'type': 'Event',
            'kind': _pausedAtStart ? 'PauseStart' : 'Resume',
            'timestamp': 0,
            'isolate': _isolateRef,
          },
        },
      'lookupPackageUris' => {
          'type': 'UriList',
          'uris': [_packageUri],
        },
      'addBreakpointWithScriptUri' => _addBreakpoint(params),
      'evaluateInFrame' => {
          'type': '@Instance',
          'kind': 'Bool',
          'id': 'objects/bool',
          'valueAsString': '$conditionResult',
          'class': {'type': '@Class', 'id': 'classes/bool', 'name': 'bool'},
        },
      'resume' => _resume(params['isolateId'] as String),
      _ => {'type': 'Success'},
    };
    _incoming.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      if (result case {'error': final error})
        'error': error
      else
        'result': result,
    }));
  }

  /// Like the VM, knows the library only by its `package:` URI.
  Map<String, Object?> _addBreakpoint(Map<String, dynamic> params) {
    final uri = params['scriptUri'] as String;
    if (uri != _packageUri) {
      return {
        'error': {'code': 102, 'message': 'Cannot add breakpoint'},
      };
    }
    breakpointUris.add(uri);
    return _breakpoint;
  }

  Map<String, Object?> _resume(String isolateId) {
    resumedIsolates.add(isolateId);
    return {'type': 'Success'};
  }

  /// Another isolate stopping on an exception.
  void pauseOtherIsolate() {
    _event('Debug', {
      'type': 'Event',
      'kind': 'PauseException',
      'timestamp': 0,
      'isolate': _otherIsolateRef,
    });
  }

  static const _otherIsolateRef = {
    'type': '@Isolate',
    'id': 'isolates/2',
    'name': 'worker',
    'number': '2',
  };

  /// Another isolate the server spawned, waiting at its start.
  void startOtherIsolate() {
    _event('Debug', {
      'type': 'Event',
      'kind': 'PauseStart',
      'timestamp': 0,
      'isolate': {
        'type': '@Isolate',
        'id': 'isolates/2',
        'name': 'worker',
        'number': '2',
      },
    });
  }

  void _event(String streamId, Map<String, Object?> event) {
    _incoming.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {'streamId': streamId, 'event': event},
    }));
  }

  static const _isolateRef = {
    'type': '@Isolate',
    'id': 'isolates/1',
    'name': 'main',
    'number': '1',
  };

  static const _breakpoint = {
    'type': 'Breakpoint',
    'id': 'breakpoints/1',
    'breakpointNumber': 1,
    'enabled': true,
    'resolved': true,
    'location': {
      'type': 'SourceLocation',
      'script': {'type': '@Script', 'id': 'scripts/1', 'uri': _packageUri},
      'tokenPos': 0,
    },
  };
}

class _FakeDebug implements LumideDebug {
  final states = <LumideDebugSessionState>[];
  String? reason;
  List<LumideDebugBreakpoint> breakpoints = const [];

  void _record(LumideDebugSession session) {
    states.add(session.state);
    reason = session.stoppedReason;
  }

  @override
  Future<void> startSession(LumideDebugSession session) async =>
      _record(session);

  @override
  Future<void> updateSession(LumideDebugSession session) async =>
      _record(session);

  @override
  Future<void> updateBreakpoints(
    String sessionId,
    List<LumideDebugBreakpoint> breakpoints,
  ) async =>
      this.breakpoints = breakpoints;

  @override
  Future<void> endSession(String sessionId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOutput implements LumideOutputChannel {
  @override
  String get id => 'output';

  @override
  Future<void> appendLog(LumideLogRecord record) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeContext implements LumideContext {
  _FakeContext(this.debug);

  @override
  final LumideDebug debug;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
