import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/services/project_service.dart';
import 'package:path/path.dart' as path;

/// Runs `serverpod generate` for a server package after one of its model
/// or endpoint files is saved, or a model file is created, deleted or
/// renamed.
///
/// Changes are debounced per server. While generation runs for a server,
/// further changes queue at most one follow-up run.
class GenerateOnSave {
  GenerateOnSave({
    required String? Function(String filePath) serverRootFor,
    required Future<bool> Function(String serverRoot) shouldGenerate,
    required Future<void> Function(String serverRoot) generate,
    required Future<String?> Function(String filePath) readFile,
    this.debounce = const Duration(milliseconds: 500),
  })  : _serverRootFor = serverRootFor,
        _shouldGenerate = shouldGenerate,
        _generate = generate,
        _readFile = readFile;

  final String? Function(String filePath) _serverRootFor;
  final Future<bool> Function(String serverRoot) _shouldGenerate;
  final Future<void> Function(String serverRoot) _generate;
  final Future<String?> Function(String filePath) _readFile;
  final Duration debounce;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _rerun = {};

  /// Files that held an endpoint when last saved, so removing the endpoint
  /// from one also regenerates.
  final Set<String> _endpointFiles = {};
  bool _disposed = false;

  Future<void> handleSave(String uri) async {
    final filePath = filePathOf(uri);
    if (_disposed || filePath == null) return;
    final serverRoot = _serverRootFor(filePath);
    if (serverRoot == null) return;
    if (!await _isGenerationSource(serverRoot, filePath)) return;
    _schedule(serverRoot);
  }

  /// Regenerates when a model file appears, disappears or moves, which no
  /// save reports.
  void handleFileChange(LumideFileChange change) {
    if (change.type == LumideFileChangeType.changed) return;
    for (final uri in [
      change.uri,
      if (change.oldUri case final oldUri?) oldUri,
    ]) {
      final filePath = filePathOf(uri);
      if (filePath == null || !_isModelFile(filePath)) continue;
      if (_serverRootFor(filePath) case final serverRoot?) {
        _schedule(serverRoot);
      }
    }
  }

  void _schedule(String serverRoot) {
    if (_disposed) return;
    _timers.remove(serverRoot)?.cancel();
    _timers[serverRoot] = Timer(debounce, () {
      _timers.remove(serverRoot);
      unawaited(_run(serverRoot));
    });
  }

  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _run(String serverRoot) async {
    if (_running.contains(serverRoot)) {
      _rerun.add(serverRoot);
      return;
    }
    _running.add(serverRoot);
    try {
      do {
        _rerun.remove(serverRoot);
        if (!await _shouldGenerate(serverRoot)) return;
        await _generate(serverRoot);
      } while (_rerun.contains(serverRoot) && !_disposed);
    } catch (_) {
      // generate reports its own failures.
    } finally {
      _running.remove(serverRoot);
      _rerun.remove(serverRoot);
    }
  }

  /// Model files anywhere in the server, and endpoints in its `lib` outside
  /// the generated code.
  Future<bool> _isGenerationSource(String serverRoot, String filePath) async {
    if (_isModelFile(filePath)) return true;
    if (path.extension(filePath) != '.dart') return false;

    final libDirectory = path.join(serverRoot, 'lib');
    final generatedDirectory = path.join(libDirectory, 'src', 'generated');
    if (!path.isWithin(libDirectory, filePath)) return false;
    if (path.isWithin(generatedDirectory, filePath)) return false;

    final source = await _readFile(filePath);
    final isEndpoint = source != null && isEndpointSource(source);
    final wasEndpoint = switch (isEndpoint) {
      true => !_endpointFiles.add(filePath),
      false => _endpointFiles.remove(filePath),
    };
    return isEndpoint || wasEndpoint;
  }

  static bool _isModelFile(String filePath) {
    final lowerPath = filePath.toLowerCase();
    return modelFileExtensions.any(lowerPath.endsWith);
  }

  /// Whether [source] declares an endpoint: a class extending `Endpoint`
  /// or another endpoint, such as `EmailIdpBaseEndpoint`.
  static bool isEndpointSource(String source) =>
      _endpointClass.hasMatch(source);

  static final _endpointClass = RegExp(
    r'\bclass\s+\w+(?:\s*<[^{]*?>)?\s+extends\s+[\w.]*Endpoint\b',
  );
}
