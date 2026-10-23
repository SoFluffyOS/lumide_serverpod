import 'dart:async';

import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/services/project_service.dart';
import 'package:path/path.dart' as path;

/// Runs `serverpod generate` for a server package after one of its model
/// or endpoint files is saved.
///
/// Saves are debounced per server. While generation runs for a server,
/// further saves queue at most one follow-up run.
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
  bool _disposed = false;

  Future<void> handleSave(String uri) async {
    final filePath = filePathOf(uri);
    if (_disposed || filePath == null) return;
    final serverRoot = _serverRootFor(filePath);
    if (serverRoot == null) return;
    if (!await _isGenerationSource(serverRoot, filePath)) return;
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
    if (!await _shouldGenerate(serverRoot)) return;

    _running.add(serverRoot);
    try {
      do {
        _rerun.remove(serverRoot);
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
    final lowerPath = filePath.toLowerCase();
    if (modelFileExtensions.any(lowerPath.endsWith)) return true;
    if (path.extension(filePath) != '.dart') return false;

    final libDirectory = path.join(serverRoot, 'lib');
    final generatedDirectory = path.join(libDirectory, 'src', 'generated');
    if (!path.isWithin(libDirectory, filePath)) return false;
    if (path.isWithin(generatedDirectory, filePath)) return false;

    final source = await _readFile(filePath);
    return source != null && source.contains(_endpointMarker);
  }

  static const _endpointMarker = 'extends Endpoint';
}
