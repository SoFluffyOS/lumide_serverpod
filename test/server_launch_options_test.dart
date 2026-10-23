import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  const serverpod4 = ServerpodVersion(4, 0, 4);
  const serverpod3 = ServerpodVersion(3, 4, 13);

  group('ServerpodVersion.parse', () {
    test('reads the version serverpod version prints', () {
      final version = ServerpodVersion.parse('Serverpod version: 4.0.4\n');

      expect(version?.toString(), '4.0.4');
      expect(version?.supportsStart, isTrue);
    });

    test('knows serverpod start is new in Serverpod 4', () {
      expect(serverpod3.supportsStart, isFalse);
    });

    test('returns null without a version', () {
      expect(ServerpodVersion.parse('command not found: serverpod'), isNull);
    });
  });

  group('command', () {
    test('starts Serverpod 4 servers with serverpod start', () {
      final command = const ServerLaunchOptions().command(serverpod4);

      expect(command.executable, 'serverpod');
      expect(command.arguments, [
        'start',
        '--no-tui',
        '--no-flutter',
        '--',
        '--mode',
        'development',
      ]);
    });

    test('passes start options and server arguments', () {
      final command = const ServerLaunchOptions(
        mode: 'staging',
        applyMigrations: true,
        launchFlutterApps: true,
        watch: false,
        docker: false,
        serverArgs: ['--server-id', 'a'],
      ).command(serverpod4);

      expect(command.arguments, [
        'start',
        '--no-tui',
        '--no-watch',
        '--flutter',
        '--no-docker',
        '--',
        '--mode',
        'staging',
        '--apply-migrations',
        '--server-id',
        'a',
      ]);
    });

    test('runs bin/main.dart before Serverpod 4 or without the CLI', () {
      const options = ServerLaunchOptions(applyMigrations: true);

      for (final version in [serverpod3, null]) {
        final command = options.command(version);
        expect(command.executable, 'dart');
        expect(command.arguments, [
          'bin/main.dart',
          '--mode',
          'development',
          '--apply-migrations',
        ]);
      }
    });
  });

  group('fromConfig', () {
    const defaults = ServerLaunchOptions(
      mode: 'staging',
      applyMigrations: true,
    );

    test('keeps the defaults for missing or invalid values', () {
      final options = ServerLaunchOptions.fromConfig(
        {'mode': 'testing', 'applyMigrations': 'yes'},
        defaults: defaults,
      );

      expect(options.mode, 'staging');
      expect(options.applyMigrations, isTrue);
      expect(options.watch, isTrue);
      expect(options.docker, isNull);
    });

    test('takes the values the configuration sets', () {
      final options = ServerLaunchOptions.fromConfig(
        {
          'mode': 'production',
          'applyMigrations': false,
          'docker': true,
          'serverArgs': ['--role', 'serverless'],
        },
        defaults: defaults,
      );

      expect(options.mode, 'production');
      expect(options.applyMigrations, isFalse);
      expect(options.docker, isTrue);
      expect(options.serverArgs, ['--role', 'serverless']);
    });
  });

  group('resolveServerPath', () {
    final folder = path.join(path.current, 'workspace');

    test('expands the workspace folder variable', () {
      expect(
        resolveServerPath(
          r'${workspaceFolder}/app_server',
          workspaceFolder: folder,
        ),
        path.join(folder, 'app_server'),
      );
    });

    test('takes relative paths from the workspace folder', () {
      expect(
        resolveServerPath('app_server/', workspaceFolder: folder),
        path.join(folder, 'app_server'),
      );
    });

    test('keeps absolute paths', () {
      final absolute = path.join(path.current, 'elsewhere', 'app_server');

      expect(
        resolveServerPath(absolute, workspaceFolder: folder),
        absolute,
      );
    });

    test('returns null when no server is named', () {
      expect(resolveServerPath(null, workspaceFolder: folder), isNull);
      expect(resolveServerPath('  ', workspaceFolder: folder), isNull);
    });
  });
}
