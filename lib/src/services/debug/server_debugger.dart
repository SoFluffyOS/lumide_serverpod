import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/services/debug/breakpoint_conditions.dart';
import 'package:lumide_serverpod/src/services/debug/debug_inspector.dart';
import 'package:lumide_serverpod/src/services/log_service.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Debugs one running server through its VM service, as one Lumide debug
/// session.
///
/// The server's VM service can go away while the server keeps running:
/// `serverpod start` restarts the server process behind a proxy that keeps
/// its address. The debugger then reconnects and installs the breakpoints
/// again.
class ServerDebugger {
  ServerDebugger({
    required this.context,
    required this.sessionId,
    required this.name,
    required this.serverRoot,
    required this.output,
    required this.logService,
    this.pausesOnStart = false,
    Future<VmService> Function(String uri)? connect,
    this.reconnectDelay = const Duration(milliseconds: 250),
    this.maxReconnectDelay = const Duration(seconds: 5),
    this.releaseTimeout = const Duration(seconds: 2),
  })  : _connectTo = connect ?? vmServiceConnectUri,
        _resumeAtStart = pausesOnStart;

  final LumideContext context;
  final String sessionId;
  final String name;
  final String serverRoot;

  /// The server's output channel: the debug console, and where logpoints
  /// print.
  final LumideOutputChannel output;
  final LogService logService;

  /// Whether the server's isolates wait at their start, so breakpoints are
  /// installed before any code runs.
  final bool pausesOnStart;

  /// The first wait between connection attempts; it doubles up to
  /// [maxReconnectDelay]. Attempts go on until the debugger ends, which
  /// happens when the server exits.
  final Duration reconnectDelay;
  final Duration maxReconnectDelay;

  /// How long [release] may take before the server is stopped anyway.
  final Duration releaseTimeout;

  final Future<VmService> Function(String uri) _connectTo;
  final DebugInspector _inspector = DebugInspector();

  static const _capabilities = LumideDebugCapabilities(
    canLaunch: true,
    canContinue: true,
    canPause: true,
    canStepOver: true,
    canStepInto: true,
    canStepOut: true,
    canStop: true,
    canSetBreakpoints: true,
    canEvaluate: true,
  );

  /// How long a server paused at its start waits for Lumide's breakpoints.
  static const _breakpointWait = Duration(seconds: 5);

  VmService? _service;
  String? _uri;
  String? _isolateId;
  Event? _pauseEvent;
  int _generation = 0;
  bool _ended = false;
  final List<StreamSubscription<Event>> _subscriptions = [];

  /// VM events, breakpoint changes and releases run one at a time, in
  /// order, so a late pause cannot overwrite a resume and two breakpoint
  /// syncs cannot install the same breakpoint twice.
  Future<void> _queue = Future<void>.value();
  bool _pushScheduled = false;

  bool _resumeAtStart;
  bool _receivedBreakpoints = false;
  List<LumideDebugBreakpoint> _requested = const [];
  Map<String, _InstalledBreakpoint> _installed = {};
  final Set<String> _reportedFailures = {};

  LumideDebugExceptionPauseMode _exceptionPauseMode =
      LumideDebugExceptionPauseMode.unhandled;
  LumideDebugSessionState _state = LumideDebugSessionState.launching;
  String? _stoppedReason;
  String? _statusMessage;
  int? _activeFrameId;

  bool get isAttached => _uri != null;

  /// Announces the session while the server starts.
  Future<void> start() async {
    _statusMessage = 'Starting $name…';
    await context.debug.startSession(_session());
  }

  /// Connects to the VM service at [uri], a WebSocket address.
  Future<void> attach(String uri) async {
    if (_ended || _uri != null) return;
    _uri = uri;
    await _connect();
  }

  /// Leaves the server running freely, so it can shut down: removes the
  /// breakpoints and resumes it when paused. Gives up after
  /// [releaseTimeout], so a wedged server can still be stopped.
  Future<void> release() async {
    _requested = const [];
    _exceptionPauseMode = LumideDebugExceptionPauseMode.none;
    try {
      await _serially(_release).timeout(releaseTimeout);
    } on TimeoutException {
      logService.warn('$name did not answer the debugger; stopping it.');
    }
  }

  Future<void> _release() async {
    final service = _service;
    final isolateId = _isolateId;
    if (service == null || isolateId == null) return;
    try {
      await service.setIsolatePauseMode(
        isolateId,
        exceptionPauseMode: ExceptionPauseMode.kNone,
      );
      await _syncBreakpoints();
      if (_state == LumideDebugSessionState.paused) {
        await service.resume(isolateId);
      }
    } catch (error) {
      logService.warn('Could not release $name from the debugger: $error');
    }
  }

  /// Ends the session and disconnects.
  Future<void> end({String? message}) async {
    if (_ended) return;
    _ended = true;
    _generation++;
    await _disconnect();
    try {
      if (message != null) {
        await _update(LumideDebugSessionState.terminated, message: message);
      }
      await context.debug.endSession(sessionId);
    } catch (error) {
      logService.warn('Could not end the debug session: $error');
    }
  }

  Future<void> resume() => _resume();

  Future<void> pause() async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return;
    await service.pause(isolateId);
  }

  Future<void> stepOver() => _resume(
        switch (_pauseEvent?.atAsyncSuspension) {
          true => StepOption.kOverAsyncSuspension,
          _ => StepOption.kOver,
        },
      );

  Future<void> stepInto() => _resume(StepOption.kInto);

  Future<void> stepOut() => _resume(StepOption.kOut);

  Future<void> setBreakpoints(List<LumideDebugBreakpoint> breakpoints) {
    return _serially(() async {
      _requested = {
        for (final breakpoint in breakpoints) _keyFor(breakpoint): breakpoint,
      }.values.toList();
      _receivedBreakpoints = true;
      await _syncBreakpoints();
      _schedulePush();
      await _resumeAtStartIfReady();
    });
  }

  Future<void> setExceptionPauseMode(LumideDebugExceptionPauseMode mode) async {
    _exceptionPauseMode = mode;
    final (service, isolateId) = (_service, _isolateId);
    if (service != null && isolateId != null) {
      try {
        await service.setIsolatePauseMode(
          isolateId,
          exceptionPauseMode: _vmPauseMode(mode),
        );
      } catch (error) {
        logService.warn('Could not set the exception pause mode: $error');
      }
    }
    await context.debug.updateSession(_session());
  }

  Future<List<LumideDebugStackFrame>> stackFrames() async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return const [];
    try {
      return await _inspector.stackFrames(service, isolateId);
    } catch (error) {
      logService.warn('Could not load the stack: $error');
      return const [];
    }
  }

  Future<List<LumideDebugScope>> scopes(int frameId) async =>
      _inspector.scopes(frameId);

  Future<List<LumideDebugVariable>> variables(int reference) async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return const [];
    try {
      return await _inspector.variables(service, isolateId, reference);
    } catch (error) {
      logService.warn('Could not load variables: $error');
      return const [];
    }
  }

  Future<LumideDebugEvaluationResult?> evaluate(
    String expression, {
    int? frameId,
  }) async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return null;
    return _inspector.evaluate(
      service,
      isolateId,
      expression,
      frameId: frameId,
    );
  }

  Future<void> _connect() async {
    final uri = _uri;
    if (uri == null) return;
    final generation = ++_generation;

    VmService? service;
    var delay = reconnectDelay;
    while (service == null) {
      if (_ended || generation != _generation) return;
      try {
        service = await _connectTo(uri);
      } catch (_) {
        await Future<void>.delayed(delay);
        delay = switch (delay * 2 < maxReconnectDelay) {
          true => delay * 2,
          false => maxReconnectDelay,
        };
      }
    }
    if (_ended || generation != _generation) {
      await service.dispose();
      return;
    }

    _service = service;
    unawaited(service.onDone.then((_) => _handleDisconnect(generation)));
    try {
      // Listen before subscribing, so no event the VM sends right after is
      // missed.
      _subscriptions
        ..add(service.onDebugEvent.listen(_enqueueEvent))
        ..add(service.onIsolateEvent.listen(_enqueueEvent));
      await service.streamListen(EventStreams.kDebug);
      await service.streamListen(EventStreams.kIsolate);
      await _serially(_selectIsolate);
    } catch (error) {
      logService.error('Could not attach the debugger to $name', error);
    }
  }

  Future<void> _handleDisconnect(int generation) async {
    if (_ended || generation != _generation) return;
    await _disconnect();
    await _update(
      LumideDebugSessionState.running,
      message: 'Reconnecting to the restarted server…',
    );
    await _connect();
  }

  Future<void> _disconnect() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final service = _service;
    _service = null;
    _isolateId = null;
    _pauseEvent = null;
    _installed = {};
    _inspector.clear();
    try {
      await service?.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      // The connection is already gone.
    }
  }

  Future<void> _selectIsolate() async {
    final service = _service;
    if (service == null) return;
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) {
      await _update(LumideDebugSessionState.running, message: 'Running');
      return;
    }
    final main = isolates.firstWhere(
      (isolate) => isolate.name == 'main',
      orElse: () => isolates.first,
    );
    final isolateId = main.id;
    if (isolateId == null) return;
    await _useIsolate(isolateId);

    final isolate = await service.getIsolate(isolateId);
    final pauseEvent = isolate.pauseEvent;
    if (pauseEvent == null) return;
    await _handleEvent(pauseEvent);
  }

  Future<void> _useIsolate(String isolateId) async {
    if (_isolateId == isolateId) return;
    final service = _service;
    if (service == null) return;
    _isolateId = isolateId;
    _installed = {};
    _inspector.clear();
    try {
      await service.setIsolatePauseMode(
        isolateId,
        exceptionPauseMode: _vmPauseMode(_exceptionPauseMode),
      );
    } catch (error) {
      logService.warn('Could not set the exception pause mode: $error');
    }
    if (!_receivedBreakpoints) return;
    await _syncBreakpoints();
    _schedulePush();
  }

  void _enqueueEvent(Event event) {
    unawaited(_serially(() => _handleEvent(event)));
  }

  /// Runs [action] after everything queued before it. Its errors are
  /// logged, not thrown, since nothing awaits most queued work.
  Future<void> _serially(Future<void> Function() action) {
    final result = _queue.then((_) async {
      try {
        await action();
      } catch (error) {
        if (!_ended) logService.warn('Debugger: $error');
      }
    });
    _queue = result;
    return result;
  }

  Future<void> _handleEvent(Event event) async {
    final kind = event.kind;
    final isolateId = event.isolate?.id;
    if (kind == null || _ended) return;

    // One isolate is debugged: the server's main one. Breakpoints and the
    // exception pause mode are set in it alone, so other isolates only
    // pause at their start, when the server waits there for breakpoints.
    final otherIsolate =
        isolateId != null && _isolateId != null && isolateId != _isolateId;
    if (otherIsolate) {
      if (kind == EventKind.kPauseStart) await _service?.resume(isolateId);
      return;
    }
    if (isolateId != null && _isolateId == null) {
      await _useIsolate(isolateId);
    }

    switch (kind) {
      case EventKind.kPauseStart:
        _pauseEvent = event;
        if (_resumeAtStart) {
          await _resumeAtStartIfReady();
          unawaited(
            Future<void>.delayed(
              _breakpointWait,
              () => _serially(_resumeAtStartWithoutBreakpoints),
            ),
          );
          return;
        }
        await _showPaused(event);
      case EventKind.kPauseBreakpoint:
        _pauseEvent = event;
        if (await _resumeIfConditionsAreFalse(event)) return;
        await _showPaused(event);
      case EventKind.kPauseInterrupted ||
            EventKind.kPauseException ||
            EventKind.kPausePostRequest:
        _pauseEvent = event;
        await _showPaused(event);
      case EventKind.kResume:
        _pauseEvent = null;
        _inspector.clear();
        await _update(LumideDebugSessionState.running, message: 'Running');
      case EventKind.kNone:
        await _update(LumideDebugSessionState.running, message: 'Running');
      case EventKind.kBreakpointAdded ||
            EventKind.kBreakpointResolved ||
            EventKind.kBreakpointRemoved:
        _applyBreakpointEvent(kind, event.breakpoint);
        _schedulePush();
      case EventKind.kIsolateRunnable || EventKind.kIsolateReload:
        if (!_receivedBreakpoints) return;
        await _syncBreakpoints();
        _schedulePush();
      case EventKind.kIsolateExit:
        _isolateId = null;
        _installed = {};
        _inspector.clear();
    }
  }

  Future<void> _showPaused(Event event) async {
    final reason = switch (event.kind) {
      EventKind.kPauseStart => 'entry',
      EventKind.kPauseException => 'exception',
      EventKind.kPauseInterrupted => 'pause',
      EventKind.kPauseBreakpoint
          when (event.pauseBreakpoints ?? const []).isNotEmpty =>
        'breakpoint',
      _ => 'step',
    };
    final message = switch (reason) {
      'exception' => await _exceptionMessage(event),
      'entry' => 'Paused at start.',
      'breakpoint' => 'Paused on breakpoint.',
      'pause' => 'Paused.',
      _ => 'Paused after stepping.',
    };
    await _update(
      LumideDebugSessionState.paused,
      reason: reason,
      message: message,
      activeFrameId: event.topFrame?.index,
    );
  }

  Future<String> _exceptionMessage(Event event) async {
    final (service, isolateId) = (_service, _isolateId);
    final exception = event.exception;
    if (service == null || isolateId == null || exception == null) {
      return 'Paused on exception.';
    }
    final text = await _inspector.describe(service, isolateId, exception);
    return 'Paused on exception: $text';
  }

  Future<void> _resume([String? step]) async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return;
    await service.resume(isolateId, step: step);
  }

  /// Resumes a server waiting at its start once its breakpoints are in.
  Future<void> _resumeAtStartIfReady() async {
    final waitingAtStart = _pauseEvent?.kind == EventKind.kPauseStart;
    if (!_resumeAtStart || !waitingAtStart || !_receivedBreakpoints) return;
    _resumeAtStart = false;
    await _resume();
  }

  /// Resumes a server waiting at its start without breakpoints, when
  /// Lumide sends none.
  Future<void> _resumeAtStartWithoutBreakpoints() async {
    final waitingAtStart = _pauseEvent?.kind == EventKind.kPauseStart;
    if (!_resumeAtStart || !waitingAtStart || _ended) return;
    _resumeAtStart = false;
    await _resume();
  }

  /// Applies breakpoint conditions and logpoints on pause, since the VM has
  /// neither. Prints logpoint messages, then resumes and returns true when
  /// no hit breakpoint should stop.
  Future<bool> _resumeIfConditionsAreFalse(Event event) async {
    final (service, isolateId) = (_service, _isolateId);
    final hitIds = {
      for (final breakpoint in event.pauseBreakpoints ?? const <Breakpoint>[])
        if (breakpoint.id case final id?) id,
    };
    if (service == null || isolateId == null || hitIds.isEmpty) return false;

    final hits = <HitBreakpoint>[
      for (final installed in _installed.values)
        if (installed.vmBreakpoint?.id case final id? when hitIds.contains(id))
          (
            condition: installed.requested.condition,
            logMessage: installed.requested.logMessage,
          ),
    ];
    if (hits.length != hitIds.length) return false;

    final decision = await decideBreakpointPause(
      breakpoints: hits,
      evaluate: (expression) => _condition(service, isolateId, expression),
    );
    for (final template in decision.logMessages) {
      final message = await formatLogMessage(
        template,
        (expression) => _logValue(service, isolateId, expression),
      );
      await output.appendLog(
        LumideLogRecord(
          level: 'INFO',
          message: message,
          name: 'Logpoint',
          time: DateTime.now(),
        ),
      );
    }
    if (!decision.resume) return false;
    await service.resume(isolateId);
    return true;
  }

  Future<bool?> _condition(
    VmService service,
    String isolateId,
    String expression,
  ) async {
    try {
      final result = await service.evaluateInFrame(
        isolateId,
        0,
        expression,
        disableBreakpoints: true,
      );
      if (result
          case InstanceRef(kind: InstanceKind.kBool, :final valueAsString)) {
        return valueAsString == 'true';
      }
      await _reportOnce(
        expression,
        'Breakpoint condition "$expression" is not a bool.',
      );
    } catch (error) {
      await _reportOnce(
        expression,
        'Breakpoint condition "$expression" failed: $error',
      );
    }
    return null;
  }

  Future<String?> _logValue(
    VmService service,
    String isolateId,
    String expression,
  ) async {
    try {
      final result = await service.evaluateInFrame(
        isolateId,
        0,
        '($expression).toString()',
        disableBreakpoints: true,
      );
      if (result case InstanceRef(:final valueAsString?)) return valueAsString;
      if (result case ErrorRef(:final message?)) throw StateError(message);
      throw StateError('No value');
    } catch (error) {
      await _reportOnce(
        'log:$expression',
        'Logpoint expression "$expression" failed: $error',
      );
      return null;
    }
  }

  /// Broken conditions and logpoint expressions are reported once per
  /// session, not on every hit.
  Future<void> _reportOnce(String key, String message) async {
    if (!_reportedFailures.add(key)) return;
    await output.appendLog(
      LumideLogRecord(level: 'ERROR', message: message, name: 'Debugger'),
    );
  }

  Future<void> _syncBreakpoints() async {
    final (service, isolateId) = (_service, _isolateId);
    if (service == null || isolateId == null) return;

    final desired = {
      for (final breakpoint in _requested)
        if (breakpoint.enabled) _keyFor(breakpoint): breakpoint,
    };

    for (final key in _installed.keys.toList()) {
      if (desired.containsKey(key)) continue;
      final installed = _installed.remove(key);
      final id = installed?.vmBreakpoint?.id;
      if (id == null) continue;
      try {
        await service.removeBreakpoint(isolateId, id);
      } catch (_) {
        // The breakpoint went away with a reload.
      }
    }

    for (final MapEntry(key: key, value: breakpoint) in desired.entries) {
      final existing = _installed[key];
      if (existing?.vmBreakpoint case final vmBreakpoint?) {
        _installed[key] = _InstalledBreakpoint(breakpoint, vmBreakpoint);
        continue;
      }
      try {
        final vmBreakpoint = await _addBreakpoint(
          service,
          isolateId,
          breakpoint,
        );
        _installed[key] = _InstalledBreakpoint(breakpoint, vmBreakpoint);
      } catch (error) {
        _installed[key] = _InstalledBreakpoint(
          breakpoint,
          null,
          message: '$error',
        );
      }
    }
  }

  /// Adds [breakpoint] by its file URI, then by its `package:` URI, which
  /// the VM knows libraries by.
  Future<Breakpoint> _addBreakpoint(
    VmService service,
    String isolateId,
    LumideDebugBreakpoint breakpoint,
  ) async {
    final candidates = [breakpoint.sourceUri];
    if (Uri.tryParse(breakpoint.sourceUri)?.scheme == 'file') {
      try {
        final lookup =
            await service.lookupPackageUris(isolateId, [breakpoint.sourceUri]);
        if (lookup.uris case [final String packageUri, ...]) {
          candidates.add(packageUri);
        }
      } catch (_) {
        // Fall back to the file URI alone.
      }
    }

    Object? lastError;
    for (final uri in candidates) {
      try {
        return await service.addBreakpointWithScriptUri(
          isolateId,
          uri,
          breakpoint.line,
          column: breakpoint.column,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No script for ${breakpoint.sourceUri}');
  }

  void _applyBreakpointEvent(String kind, Breakpoint? breakpoint) {
    final id = breakpoint?.id;
    if (breakpoint == null || id == null) return;
    for (final MapEntry(key: key, value: installed) in _installed.entries) {
      if (installed.vmBreakpoint?.id != id) continue;
      if (kind == EventKind.kBreakpointRemoved) {
        _installed.remove(key);
        return;
      }
      _installed[key] = _InstalledBreakpoint(installed.requested, breakpoint);
      return;
    }
  }

  /// Sends the breakpoints once for a burst of changes, such as the VM
  /// resolving each breakpoint of a sync.
  void _schedulePush() {
    if (_pushScheduled) return;
    _pushScheduled = true;
    Timer.run(() {
      _pushScheduled = false;
      unawaited(_pushBreakpoints());
    });
  }

  Future<void> _pushBreakpoints() async {
    if (_ended) return;
    final breakpoints = [
      for (final breakpoint in _requested)
        _withState(breakpoint, _installed[_keyFor(breakpoint)]),
    ];
    try {
      await context.debug.updateBreakpoints(sessionId, breakpoints);
    } catch (error) {
      logService.warn('Could not update breakpoints: $error');
    }
  }

  LumideDebugBreakpoint _withState(
    LumideDebugBreakpoint breakpoint,
    _InstalledBreakpoint? installed,
  ) {
    final vmBreakpoint = installed?.vmBreakpoint;
    final verified = vmBreakpoint?.resolved ?? false;
    return LumideDebugBreakpoint(
      id: vmBreakpoint?.id ?? breakpoint.id,
      sourceUri: breakpoint.sourceUri,
      line: breakpoint.line,
      column: breakpoint.column,
      endLine: breakpoint.endLine,
      endColumn: breakpoint.endColumn,
      condition: breakpoint.condition,
      logMessage: breakpoint.logMessage,
      enabled: breakpoint.enabled,
      verified: verified,
      message: switch ((breakpoint.enabled, installed, verified)) {
        (false, _, _) => 'Disabled',
        (_, _, true) => null,
        (_, _InstalledBreakpoint(:final message?), _) => message,
        (_, null, _) when _isolateId == null => 'Waiting for the server',
        (_, null, _) => 'Pending install',
        _ => 'Pending resolution',
      },
    );
  }

  Future<void> _update(
    LumideDebugSessionState state, {
    String? reason,
    String? message,
    int? activeFrameId,
  }) async {
    _state = state;
    _stoppedReason = reason;
    _statusMessage = message;
    _activeFrameId = activeFrameId;
    try {
      await context.debug.updateSession(_session());
    } catch (error) {
      logService.warn('Could not update the debug session: $error');
    }
  }

  LumideDebugSession _session() => LumideDebugSession(
        id: sessionId,
        name: name,
        state: _state,
        capabilities: _capabilities,
        outputChannelId: output.id,
        stoppedReason: _stoppedReason,
        statusMessage: _statusMessage,
        activeFrameId: _activeFrameId,
        exceptionPauseMode: _exceptionPauseMode,
      );

  static String _keyFor(LumideDebugBreakpoint breakpoint) =>
      '${breakpoint.sourceUri}:${breakpoint.line}:${breakpoint.column ?? 0}';

  static String _vmPauseMode(LumideDebugExceptionPauseMode mode) =>
      switch (mode) {
        LumideDebugExceptionPauseMode.none => ExceptionPauseMode.kNone,
        LumideDebugExceptionPauseMode.unhandled =>
          ExceptionPauseMode.kUnhandled,
        LumideDebugExceptionPauseMode.all => ExceptionPauseMode.kAll,
      };
}

class _InstalledBreakpoint {
  const _InstalledBreakpoint(this.requested, this.vmBreakpoint, {this.message});

  final LumideDebugBreakpoint requested;
  final Breakpoint? vmBreakpoint;
  final String? message;
}
