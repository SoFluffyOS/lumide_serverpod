import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  final root = path.join(path.current, 'my_project', 'my_project_server');

  group('ServerPackage.parse', () {
    test('reads a package that depends on serverpod', () {
      final server = ServerPackage.parse(root, '''
name: my_project_server
dependencies:
  serverpod: 4.0.4
serverpod:
  scripts:
    start: dart bin/main.dart --apply-migrations
    seed:
      posix: ./tool/seed.sh
      windows: tool\\seed.bat
''');

      expect(server?.name, 'my_project_server');
      expect(server?.root, root);
      expect(server?.scripts, ['start', 'seed']);
    });

    test('has no scripts without a scripts section', () {
      final server = ServerPackage.parse(root, '''
name: my_project_server
dependencies:
  serverpod: ^3.4.0
''');

      expect(server?.scripts, isEmpty);
    });

    test('ignores clients, apps and the framework itself', () {
      expect(
        ServerPackage.parse(root, '''
name: my_project_client
dependencies:
  serverpod_client: 4.0.4
'''),
        isNull,
      );
      expect(
        ServerPackage.parse(root, '''
name: my_project_flutter
dev_dependencies:
  serverpod: 4.0.4
'''),
        isNull,
      );
      expect(
        ServerPackage.parse(root, '''
name: serverpod
dependencies:
  serverpod: 4.0.4
'''),
        isNull,
      );
    });

    test('ignores invalid YAML', () {
      expect(ServerPackage.parse(root, 'name: [unclosed'), isNull);
      expect(ServerPackage.parse(root, '- a list'), isNull);
    });
  });

  test('contains its root and the files below it', () {
    final server = ServerPackage(name: 'my_project_server', root: root);

    expect(server.contains(root), isTrue);
    expect(server.contains(path.join(root, 'lib', 'server.dart')), isTrue);
    expect(server.contains('${root}_old'), isFalse);
    expect(server.contains(path.dirname(root)), isFalse);
  });

  group('filePathOf', () {
    test('converts file URIs and keeps paths', () {
      final filePath = path.join(root, 'pubspec.yaml');

      expect(filePathOf(Uri.file(filePath).toString()), filePath);
      expect(filePathOf(filePath), filePath);
    });

    test('rejects other schemes and empty values', () {
      expect(filePathOf('untitled:pubspec.yaml'), isNull);
      expect(filePathOf(''), isNull);
    });
  });
}
