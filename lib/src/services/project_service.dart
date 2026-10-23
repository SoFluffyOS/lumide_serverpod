import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:path/path.dart' as path;

/// Finds the Serverpod server packages of every workspace folder.
class ProjectService {
  ProjectService(this.context);

  final LumideContext context;

  List<ServerPackage> _servers = const [];
  int _generation = 0;

  List<ServerPackage> get servers => _servers;

  /// Scans the workspace again for server packages.
  Future<List<ServerPackage>> refresh() async {
    final generation = ++_generation;
    final pubspecs = await context.workspace.findFiles('**/pubspec.yaml');
    final folders = await _workspaceFolderPaths();
    final pubspecPaths = [
      for (final pubspec in pubspecs)
        if (filePathOf(pubspec) case final pubspecPath?
            when !isIgnoredPubspec(pubspecPath, folders))
          pubspecPath,
    ];

    final servers = <ServerPackage>[];
    for (var start = 0; start < pubspecPaths.length; start += _readBatch) {
      final batch = pubspecPaths.skip(start).take(_readBatch);
      servers.addAll([
        for (final server in await Future.wait(batch.map(_readServer)))
          if (server != null) server,
      ]);
    }
    servers.sort((first, second) => first.root.compareTo(second.root));
    if (generation == _generation) _servers = servers;
    return _servers;
  }

  /// The innermost server package holding [filePath].
  ServerPackage? serverFor(String filePath) {
    ServerPackage? match;
    for (final server in _servers) {
      if (!server.contains(filePath)) continue;
      if (match == null || server.root.length > match.root.length) {
        match = server;
      }
    }
    return match;
  }

  /// The server package to act on: the one holding the file a menu was
  /// opened on, or the active document, the only one, or the user's pick.
  Future<ServerPackage?> pickServer({
    Map<String, dynamic>? args,
    String placeholder = 'Select a Serverpod server',
  }) async {
    if (_servers.isEmpty) await refresh();
    if (_servers.isEmpty) {
      await context.window.showMessage(
        'No Serverpod server found in this workspace.',
        type: MessageType.warning,
        title: pluginName,
      );
      return null;
    }

    if (pathFromMenuContext(args) case final menuPath?) {
      if (serverFor(menuPath) case final server?) return server;
    }
    if (_servers case [final onlyServer]) return onlyServer;
    if (await _activeDocumentPath() case final activePath?) {
      if (serverFor(activePath) case final server?) return server;
    }

    final selected = await context.window.showQuickPick(
      [
        for (final server in _servers)
          QuickPickItem(
            label: server.name,
            description: server.root,
            payload: server.root,
            icon: iconServer,
          ),
      ],
      placeholder: placeholder,
    );
    final root = selected?.payload;
    if (root is! String) return null;
    for (final server in _servers) {
      if (server.root == root) return server;
    }
    return null;
  }

  /// The folder new projects go in: the folder a menu was opened on, or the
  /// first workspace folder.
  Future<String?> targetFolder(Map<String, dynamic>? args) async {
    if (pathFromMenuContext(args) case final menuPath?) {
      if (await context.fs.isDirectory(menuPath)) return menuPath;
      return path.dirname(menuPath);
    }
    return filePathOf(await context.workspace.getRootUri() ?? '');
  }

  /// The path a context menu action was invoked on.
  String? pathFromMenuContext(Map<String, dynamic>? args) {
    final menuContext = _mapValue(args, 'context');
    if (menuContext == null) return null;

    for (final candidate in [
      _mapValue(menuContext, 'file'),
      _mapValue(_mapValue(menuContext, 'tab'), 'file'),
      _mapValue(menuContext, 'primary'),
    ]) {
      if (_pathValue(candidate) case final candidatePath?) {
        return candidatePath;
      }
    }

    if (menuContext['selectedPaths'] case [final String first, ...]
        when first.isNotEmpty) {
      return first;
    }
    return null;
  }

  Future<String?> _activeDocumentPath() async {
    try {
      final uri = await context.editor.getActiveDocumentUri();
      if (uri == null) return null;
      return filePathOf(uri);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _mapValue(Map? source, String key) {
    final value = source?[key];
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String? _pathValue(Map<String, dynamic>? map) {
    if (map == null) return null;
    if (map['path'] case final String filePath when filePath.isNotEmpty) {
      return filePath;
    }
    if (map['uri'] case final String uri when uri.isNotEmpty) {
      return filePathOf(uri);
    }
    return null;
  }

  Future<ServerPackage?> _readServer(String pubspecPath) async {
    try {
      final text = await context.fs.readString(pubspecPath);
      return ServerPackage.parse(path.dirname(pubspecPath), text);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _workspaceFolderPaths() async {
    try {
      final folders = await context.workspace.getWorkspaceFolders();
      return [
        for (final folder in folders)
          if (filePathOf(folder.uri) case final folderPath?) folderPath,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [pubspecPath] is a copy in build output or tool caches. Only
  /// the part inside its workspace folder counts, so a workspace that
  /// itself lives under a `build` folder is still scanned.
  static bool isIgnoredPubspec(String pubspecPath, List<String> folders) {
    var relative = pubspecPath;
    for (final folder in folders) {
      if (!path.isWithin(folder, pubspecPath)) continue;
      relative = path.relative(pubspecPath, from: folder);
      break;
    }
    return path.split(relative).any(_ignoredSegments.contains);
  }

  static const _ignoredSegments = {'.dart_tool', 'build', '.symlinks'};

  /// How many pubspecs are read at once.
  static const _readBatch = 16;
}

/// The native path of a `file:` URI, or [uriOrPath] itself when it is
/// already a path. Null for other schemes and empty values.
String? filePathOf(String uriOrPath) {
  if (uriOrPath.isEmpty) return null;
  final uri = Uri.tryParse(uriOrPath);
  if (uri == null || !uri.hasScheme || uri.scheme.length == 1) {
    return uriOrPath;
  }
  if (uri.scheme != 'file') return null;
  return uri.toFilePath();
}
