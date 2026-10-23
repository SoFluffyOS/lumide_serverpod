import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/services/debug/server_debugger.dart';

/// Routes Lumide's debugger requests to the server being debugged.
///
/// Lumide shows one debug session at a time, so one server is debugged at a
/// time.
class DebugSessions {
  DebugSessions(
    this.context, {
    required this.onLaunch,
    required this.onStop,
  });

  final LumideContext context;

  /// Starts debugging, from Lumide's debug controls.
  final Future<void> Function() onLaunch;

  /// Stops the server [debugger] debugs.
  final Future<void> Function(ServerDebugger debugger) onStop;

  ServerDebugger? _active;

  ServerDebugger? get active => _active;

  void init() {
    context.debug
      ..onLaunch(onLaunch)
      ..onContinue((id) => _on(id, (debugger) => debugger.resume()))
      ..onPause((id) => _on(id, (debugger) => debugger.pause()))
      ..onStepOver((id) => _on(id, (debugger) => debugger.stepOver()))
      ..onStepInto((id) => _on(id, (debugger) => debugger.stepInto()))
      ..onStepOut((id) => _on(id, (debugger) => debugger.stepOut()))
      ..onStop((id) => _on(id, onStop))
      ..onSetBreakpoints(
        (id, breakpoints) =>
            _on(id, (debugger) => debugger.setBreakpoints(breakpoints)),
      )
      ..onSetExceptionPauseMode(
        (id, mode) =>
            _on(id, (debugger) => debugger.setExceptionPauseMode(mode)),
      )
      ..onGetStackFrames(
        (id) async => await _find(id)?.stackFrames() ?? const [],
      )
      ..onGetScopes(
        (id, frameId) async => await _find(id)?.scopes(frameId) ?? const [],
      )
      ..onGetVariables(
        (id, reference) async =>
            await _find(id)?.variables(reference) ?? const [],
      )
      ..onEvaluate(
        (id, expression, {frameId}) async =>
            _find(id)?.evaluate(expression, frameId: frameId),
      );
  }

  /// Makes [debugger] the active session; false when another server is
  /// being debugged.
  bool open(ServerDebugger debugger) {
    if (_active != null) return false;
    _active = debugger;
    return true;
  }

  void close(ServerDebugger debugger) {
    if (identical(_active, debugger)) _active = null;
  }

  ServerDebugger? _find(String sessionId) {
    final debugger = _active;
    if (debugger == null || debugger.sessionId != sessionId) return null;
    return debugger;
  }

  Future<void> _on(
    String sessionId,
    Future<void> Function(ServerDebugger debugger) action,
  ) async {
    if (_find(sessionId) case final debugger?) await action(debugger);
  }
}
