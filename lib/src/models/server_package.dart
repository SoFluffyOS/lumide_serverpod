import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// A Serverpod server package: one whose `pubspec.yaml` depends on
/// `serverpod`.
class ServerPackage {
  const ServerPackage({
    required this.name,
    required this.root,
    this.scripts = const [],
  });

  /// The package name, such as `my_project_server`.
  final String name;

  /// Native path of the folder holding the package's `pubspec.yaml`.
  final String root;

  /// Names of the scripts in the pubspec's `serverpod/scripts` section.
  final List<String> scripts;

  bool contains(String filePath) =>
      path.equals(root, filePath) || path.isWithin(root, filePath);

  /// The server package described by [pubspec], a `pubspec.yaml` in [root],
  /// or null when it is not a Serverpod server.
  static ServerPackage? parse(String root, String pubspec) {
    final Object? document;
    try {
      document = loadYaml(pubspec);
    } on YamlException {
      return null;
    }
    if (document is! Map) return null;

    final name = document['name'];
    if (name is! String || name == 'serverpod') return null;

    final dependencies = document['dependencies'];
    if (dependencies is! Map || !dependencies.containsKey('serverpod')) {
      return null;
    }

    return ServerPackage(
      name: name,
      root: root,
      scripts: _scripts(document['serverpod']),
    );
  }

  static List<String> _scripts(Object? serverpodSection) {
    if (serverpodSection is! Map) return const [];
    final scripts = serverpodSection['scripts'];
    if (scripts is! Map) return const [];
    return [
      for (final name in scripts.keys)
        if (name is String) name,
    ];
  }
}
