import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/serverpod_version.dart';
import 'package:path/path.dart' as path;

/// The server folder a launch configuration's `server` value names, with
/// `${workspaceFolder}` replaced and relative paths taken from
/// [workspaceFolder]. Null when [value] names none.
String? resolveServerPath(Object? value, {String? workspaceFolder}) {
  if (value is! String || value.trim().isEmpty) return null;
  final folder = workspaceFolder ?? '';
  final expanded = value.trim().replaceAll(_workspaceFolderVariable, folder);
  if (path.isAbsolute(expanded) || folder.isEmpty) {
    return path.normalize(expanded);
  }
  return path.normalize(path.join(folder, expanded));
}

const _workspaceFolderVariable = r'${workspaceFolder}';

/// How to start a server: from the plugin settings, overridden by the
/// `config` of a `launch.json` entry.
class ServerLaunchOptions {
  const ServerLaunchOptions({
    this.mode = defaultRunMode,
    this.applyMigrations = defaultApplyMigrationsOnStart,
    this.launchFlutterApps = defaultLaunchFlutterApps,
    this.watch = true,
    this.docker,
    this.serverArgs = const [],
  });

  /// [defaults] with the values [config] sets.
  factory ServerLaunchOptions.fromConfig(
    Map<String, Object?> config, {
    ServerLaunchOptions defaults = const ServerLaunchOptions(),
  }) {
    return ServerLaunchOptions(
      mode: switch (config['mode']) {
        final String mode when runModes.contains(mode) => mode,
        _ => defaults.mode,
      },
      applyMigrations: switch (config['applyMigrations']) {
        final bool apply => apply,
        _ => defaults.applyMigrations,
      },
      launchFlutterApps: switch (config['launchFlutterApps']) {
        final bool launch => launch,
        _ => defaults.launchFlutterApps,
      },
      watch: switch (config['watch']) {
        final bool watch => watch,
        _ => defaults.watch,
      },
      docker: switch (config['docker']) {
        final bool docker => docker,
        _ => defaults.docker,
      },
      serverArgs: switch (config['serverArgs']) {
        final List args => [for (final arg in args) arg.toString()],
        _ => defaults.serverArgs,
      },
    );
  }

  /// The run mode: development, staging or production.
  final String mode;

  final bool applyMigrations;

  /// Whether `serverpod start` launches the companion Flutter apps.
  final bool launchFlutterApps;

  /// Whether `serverpod start` regenerates code and hot reloads on changes.
  final bool watch;

  /// Whether `serverpod start` starts Docker Compose services; null lets
  /// Serverpod decide from the project's database config.
  final bool? docker;

  /// Extra arguments for the server's `bin/main.dart`.
  final List<String> serverArgs;

  List<String> get _serverArguments => [
        '--mode',
        mode,
        if (applyMigrations) '--apply-migrations',
        ...serverArgs,
      ];

  /// The command that starts the server: `serverpod start` from Serverpod 4,
  /// `dart bin/main.dart` before it or without the CLI.
  ///
  /// `serverpod start` always serves the VM service a debugger attaches to.
  /// `dart` serves it when [debug] is set, and then waits at the start for
  /// breakpoints.
  ({String executable, List<String> arguments}) command(
    ServerpodVersion? version, {
    bool debug = false,
  }) {
    final supportsStart = version?.supportsStart ?? false;
    if (!supportsStart) {
      return (
        executable: executableDart,
        arguments: [
          if (debug) ...['--enable-vm-service=0', '--pause-isolates-on-start'],
          'bin/main.dart',
          ..._serverArguments,
        ],
      );
    }

    return (
      executable: executableServerpod,
      arguments: [
        'start',
        '--no-tui',
        if (!watch) '--no-watch',
        if (launchFlutterApps) '--flutter' else '--no-flutter',
        if (docker case final docker?)
          if (docker) '--docker' else '--no-docker',
        '--',
        ..._serverArguments,
      ],
    );
  }
}
