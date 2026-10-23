import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:lumide_serverpod/src/services/cli_service.dart';
import 'package:lumide_serverpod/src/services/log_service.dart';
import 'package:lumide_serverpod/src/services/process_hub.dart';
import 'package:lumide_serverpod/src/services/project_service.dart';
import 'package:path/path.dart' as path;

/// Runs servers from Lumide's Run controls, the Command Palette and
/// `launch.json` entries of the `serverpod` provider.
class ServerRunService {
  ServerRunService(
    this.context,
    this.projectService,
    this.cliService,
    this.processHub,
    this.logService,
  );

  final LumideContext context;
  final ProjectService projectService;
  final CliService cliService;
  final ProcessHub processHub;
  final LogService logService;

  /// Called when a server starts or stops.
  void Function()? onDidChange;

  final Map<String, _RunningServer> _running = {};
  final Map<String, Future<LumideOutputChannel>> _channels = {};

  static const _stopTimeout = Duration(seconds: 15);

  /// Names of the servers running now.
  List<String> get runningServers => [
        for (final running in _running.values) running.server.name,
      ];

  /// Whether the server in [serverRoot] runs with `serverpod start` in watch
  /// mode, which generates code itself.
  bool generatesCode(String serverRoot) {
    final running = _running[serverRoot];
    if (running == null) return false;
    return running.options.watch && running.usesStart;
  }

  Future<void> init() async {
    context.launch.onResolveConfigurations(_resolveConfigurations);
    context.launch.onConfigure(_configure);
    context.launch.onLaunch(_launch);
    await context.launch.registerProvider(
      id: launchProviderServerpod,
      title: pluginName,
      workspacePatterns: const ['pubspec.yaml'],
      kinds: const [LumideLaunchKind.run],
      defaultKinds: const [LumideLaunchKind.run],
      icon: iconServer,
      iconPath: assetIconServerpodSolid,
      configurationSchema: 'schemas/launch.schema.json',
      configurationSnippets: const [
        {
          'name': 'Serverpod Server',
          'kinds': ['run'],
          'config': {
            'server': r'${workspaceFolder}/my_project_server',
            'mode': defaultRunMode,
          },
        },
      ],
      priority: 50,
    );
    await refreshConfigurations();
  }

  /// Publishes a run configuration for every server package.
  Future<void> refreshConfigurations() async {
    final configurations = <LumideLaunchConfiguration>[];
    for (final server in projectService.servers) {
      configurations.add(await _configurationFor(server));
    }
    await context.launch.updateConfigurations(
      launchProviderServerpod,
      configurations,
    );
  }

  Future<void> start([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    await _launch(
      LumideLaunchRequest(
        providerId: launchProviderServerpod,
        kind: LumideLaunchKind.run,
        configuration: await _configurationFor(server),
      ),
    );
  }

  Future<void> stop([Map<String, dynamic>? args]) async {
    if (_running.isEmpty) {
      await context.window.showMessage(
        'No Serverpod server is running.',
        title: pluginName,
      );
      return;
    }

    if (_running.values.toList() case [final onlyServer]) {
      await _stop(onlyServer);
      return;
    }

    final selected = await context.window.showQuickPick(
      [
        for (final running in _running.values)
          QuickPickItem(
            label: running.server.name,
            description: running.options.mode,
            payload: running.server.root,
            icon: iconStop,
          ),
      ],
      placeholder: 'Stop which server?',
    );
    if (_running[selected?.payload] case final running?) {
      await _stop(running);
    }
  }

  Future<void> dispose() async {
    final running = _running.values.toList();
    await Future.wait([for (final server in running) _stop(server)]);
    try {
      await context.launch.unregisterProvider(launchProviderServerpod);
    } catch (_) {
      // Lumide already dropped the provider with the plugin.
    }
  }

  Future<List<LumideLaunchConfiguration>> _resolveConfigurations(
    LumideLaunchResolveRequest request,
  ) async {
    if (projectService.servers.isEmpty) await projectService.refresh();
    final folder = request.workspaceFolder;
    return [
      for (final server in projectService.servers)
        if (folder == null || _belongsTo(server, folder))
          await _configurationFor(server),
    ];
  }

  Future<LumideLaunchConfiguration?> _configure(
    LumideLaunchConfigureRequest request,
  ) async {
    if (request.providerId != launchProviderServerpod) return null;
    final configuration = request.configuration;
    if (request.actionId == 'stop' && configuration != null) {
      final serverRoot = await _serverRootFor(configuration);
      if (_running[serverRoot] case final running?) await _stop(running);
    }
    return configuration;
  }

  Future<void> _launch(LumideLaunchRequest request) async {
    if (request.providerId != launchProviderServerpod) return;
    final configuration = request.configuration;
    final event = LumideLaunchEvent(
      providerId: launchProviderServerpod,
      kind: request.kind,
      configurationId: configuration.id,
      workspaceFolder: configuration.workspaceFolder,
    );

    final server = await _serverFor(configuration);
    if (server == null) {
      await _endLaunch(event, message: 'No Serverpod server to start.');
      return;
    }
    if (_running.containsKey(server.root)) {
      await context.window.showMessage(
        '${server.name} is already running.',
        title: pluginName,
      );
      await _endLaunch(event, message: '${server.name} is already running.');
      return;
    }

    final options = ServerLaunchOptions.fromConfig(
      configuration.arguments,
      defaults: await _defaultOptions(server),
    );
    final version = await cliService.version();
    final command = options.command(version);
    final output = await _channelFor(server);
    await output.clear();
    if (request.revealOutput) await output.show(preserveFocus: true);
    await output.appendLine(
      '> ${command.executable} ${command.arguments.join(' ')}',
    );
    if (version == null) {
      await output.appendLine(
        'The Serverpod CLI was not found, so the server starts with dart. '
        'Start its database first, such as with "docker compose up -d".',
      );
    }

    final HostProcess process;
    try {
      process = await processHub.spawn(
        command.executable,
        command.arguments,
        workingDirectory: server.root,
      );
    } catch (error) {
      logService.error('Could not start ${server.name}', error);
      await output.appendLine('[ERROR] $error');
      await context.window.showMessage(
        'Could not start ${server.name}: $error',
        type: MessageType.error,
        title: pluginName,
      );
      await _endLaunch(event, exitCode: -1, message: '$error');
      return;
    }

    final running = _RunningServer(
      server: server,
      process: process,
      event: event,
      options: options,
      usesStart: command.executable == executableServerpod,
    );
    _running[server.root] = running;
    await context.launch.didStart(event);
    onDidChange?.call();

    final forwarding = Future.wait([
      process.stdout.forEach(output.append),
      process.stderr.forEach(output.append),
    ]);
    unawaited(_watchExit(running, output, forwarding));
  }

  Future<void> _watchExit(
    _RunningServer running,
    LumideOutputChannel output,
    Future<void> forwarding,
  ) async {
    final exitCode = await running.process.exitCode;
    await forwarding;
    if (identical(_running[running.server.root], running)) {
      _running.remove(running.server.root);
    }
    await output.appendLine('${running.server.name} stopped '
        '(exit code $exitCode).');
    await _endLaunch(running.event, exitCode: exitCode);
    onDidChange?.call();
  }

  Future<void> _stop(_RunningServer running) =>
      running.process.stop(timeout: _stopTimeout);

  Future<void> _endLaunch(
    LumideLaunchEvent event, {
    int? exitCode,
    String? message,
  }) async {
    try {
      await context.launch.didEnd(
        LumideLaunchEvent(
          providerId: event.providerId,
          kind: event.kind,
          configurationId: event.configurationId,
          workspaceFolder: event.workspaceFolder,
          exitCode: exitCode,
          message: message,
        ),
      );
    } catch (error) {
      logService.warn('Could not report the end of a launch: $error');
    }
  }

  Future<LumideLaunchConfiguration> _configurationFor(
    ServerPackage server,
  ) async {
    return LumideLaunchConfiguration(
      id: 'server:${server.root}',
      label: server.name,
      description: pluginName,
      kinds: const [LumideLaunchKind.run],
      iconPath: assetIconServerpod,
      noTint: true,
      arguments: {'server': server.root},
      workspaceFolder: await _workspaceFolderOf(server),
    );
  }

  Future<ServerPackage?> _serverFor(
    LumideLaunchConfiguration configuration,
  ) async {
    if (projectService.servers.isEmpty) await projectService.refresh();
    final serverRoot = await _serverRootFor(configuration);
    if (serverRoot != null) {
      for (final server in projectService.servers) {
        if (server.root == serverRoot) return server;
      }
      await context.window.showMessage(
        'No Serverpod server in $serverRoot.',
        type: MessageType.error,
        title: pluginName,
      );
      return null;
    }

    final folder = configuration.workspaceFolder;
    final inFolder = [
      for (final server in projectService.servers)
        if (folder == null || _belongsTo(server, folder)) server,
    ];
    if (inFolder case [final onlyServer]) return onlyServer;
    return projectService.pickServer();
  }

  Future<String?> _serverRootFor(
    LumideLaunchConfiguration configuration,
  ) async {
    return resolveServerPath(
      configuration.arguments['server'],
      workspaceFolder: configuration.workspaceFolder ??
          filePathOf(await context.workspace.getRootUri() ?? ''),
    );
  }

  Future<ServerLaunchOptions> _defaultOptions(ServerPackage server) async {
    final scope = Uri.file(server.root).toString();
    Future<Object?> setting(String key) =>
        context.workspace.getConfiguration(key, scope: scope);

    return ServerLaunchOptions.fromConfig({
      'mode': await setting(confRunMode),
      'applyMigrations': await setting(confApplyMigrationsOnStart),
      'launchFlutterApps': await setting(confLaunchFlutterApps),
    });
  }

  Future<String?> _workspaceFolderOf(ServerPackage server) async {
    try {
      final folder = await context.workspace.getWorkspaceFolder(
        Uri.file(server.root).toString(),
      );
      return filePathOf(folder?.uri ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<LumideOutputChannel> _channelFor(ServerPackage server) {
    return _channels[server.root] ??= context.window.createOutputChannel(
      '$channelServerpodServer: ${server.name}',
    );
  }

  /// Whether [server] is in [folder], or [folder] is inside [server].
  static bool _belongsTo(ServerPackage server, String folder) =>
      server.contains(folder) || path.isWithin(folder, server.root);
}

class _RunningServer {
  const _RunningServer({
    required this.server,
    required this.process,
    required this.event,
    required this.options,
    required this.usesStart,
  });

  final ServerPackage server;
  final HostProcess process;
  final LumideLaunchEvent event;
  final ServerLaunchOptions options;

  /// Whether the server runs with `serverpod start`.
  final bool usesStart;
}
