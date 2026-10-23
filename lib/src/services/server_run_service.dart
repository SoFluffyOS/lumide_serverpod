import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:lumide_serverpod/src/services/cli_service.dart';
import 'package:lumide_serverpod/src/services/debug/debug.dart';
import 'package:lumide_serverpod/src/services/log_service.dart';
import 'package:lumide_serverpod/src/services/output_writer.dart';
import 'package:lumide_serverpod/src/services/plugin_files.dart';
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

  /// Servers between the launch request and their process starting.
  final Set<String> _launching = {};

  /// Servers asked to stop while they were still starting.
  final Set<String> _stopRequested = {};
  bool _disposed = false;
  final Map<String, Future<LumideOutputChannel>> _channels = {};
  late final DebugSessions _debugSessions = DebugSessions(
    context,
    onLaunch: debug,
    onStop: (debugger) async {
      if (_running[debugger.serverRoot] case final running?) {
        await _stop(running);
      }
    },
  );

  static const _stopTimeout = Duration(seconds: 15);

  /// The supervisor's own stop, interrupt to kill, takes up to 15 seconds.
  static const _supervisedStopTimeout = Duration(seconds: 17);
  Future<String?>? _supervisorScript;

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
    _debugSessions.init();
    context.launch.onResolveConfigurations(_resolveConfigurations);
    context.launch.onConfigure(_configure);
    context.launch.onLaunch(_launch);
    await context.launch.registerProvider(
      id: launchProviderServerpod,
      title: pluginName,
      workspacePatterns: const ['pubspec.yaml'],
      kinds: _kinds,
      defaultKinds: _kinds,
      icon: iconServer,
      iconPath: assetIconServerpodSolid,
      configurationSchema: 'schemas/launch.schema.json',
      configurationSnippets: const [
        {
          'name': 'Serverpod Server',
          'kinds': ['run', 'debug'],
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

  Future<void> start([Map<String, dynamic>? args]) =>
      _start(LumideLaunchKind.run, args);

  Future<void> debug([Map<String, dynamic>? args]) =>
      _start(LumideLaunchKind.debug, args);

  Future<void> _start(
    LumideLaunchKind kind,
    Map<String, dynamic>? args,
  ) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    await _launch(
      LumideLaunchRequest(
        providerId: launchProviderServerpod,
        kind: kind,
        configuration: await _configurationFor(server),
      ),
    );
  }

  Future<void> stop([Map<String, dynamic>? args]) async {
    _stopRequested.addAll(_launching);
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
    _disposed = true;
    _stopRequested.addAll(_launching);
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
      final serverRoot = switch (await _serverRootFor(configuration)) {
        final root? => projectService.serverAt(root)?.root,
        null => null,
      };
      if (serverRoot != null && _launching.contains(serverRoot)) {
        _stopRequested.add(serverRoot);
      }
      if (_running[serverRoot] case final running?) await _stop(running);
    }
    return configuration;
  }

  Future<void> _launch(LumideLaunchRequest request) async {
    if (request.providerId != launchProviderServerpod || _disposed) return;
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
    final root = server.root;
    if (_running.containsKey(root) || _launching.contains(root)) {
      final message = '${server.name} is already running.';
      await context.window.showMessage(message, title: pluginName);
      await _endLaunch(event, message: message);
      return;
    }

    final debug = request.kind == LumideLaunchKind.debug;
    if (debug && !_debugSessions.reserve()) {
      final debugged = _debugSessions.active?.name ?? 'the other server';
      final message =
          'Stop debugging $debugged before debugging ${server.name}.';
      await context.window.showMessage(message, title: pluginName);
      await _endLaunch(event, message: message);
      return;
    }

    // Held from here, before any await, so a second launch of the same
    // server is turned away instead of starting another process.
    _launching.add(root);
    _stopRequested.remove(root);
    try {
      await _startServer(server, request, event, debug: debug);
    } finally {
      _launching.remove(root);
      _stopRequested.remove(root);
      if (debug) _debugSessions.cancelReservation();
    }
  }

  Future<void> _startServer(
    ServerPackage server,
    LumideLaunchRequest request,
    LumideLaunchEvent event, {
    required bool debug,
  }) async {
    final options = ServerLaunchOptions.fromConfig(
      request.configuration.arguments,
      defaults: await _defaultOptions(server),
    );
    final version = await cliService.version();
    final usesStart = version?.supportsStart ?? false;
    final command = options.command(version, debug: debug);
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
    if (_stopRequested.contains(server.root)) {
      await _endLaunch(event, message: '${server.name} was stopped.');
      return;
    }

    final supervisor = await _supervisor();
    final HostProcess process;
    try {
      process = await processHub.spawn(
        switch (supervisor) {
          null => command.executable,
          _ => executableDart,
        },
        [
          if (supervisor != null) ...[supervisor, command.executable],
          ...command.arguments,
        ],
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

    final debugger = switch (debug) {
      true => ServerDebugger(
          context: context,
          sessionId: 'serverpod.debug:${server.root}',
          name: server.name,
          serverRoot: server.root,
          output: output,
          logService: logService,
          pausesOnStart: !usesStart,
        ),
      false => null,
    };
    final running = _RunningServer(
      server: server,
      process: process,
      event: event,
      options: options,
      usesStart: usesStart,
      supervised: supervisor != null,
      debugger: debugger,
    );
    _running[server.root] = running;
    if (debugger != null) _debugSessions.open(debugger);

    // Output is read from the start, whatever happens below, so the
    // process never buffers it unread.
    final forwarding = _forwardOutput(
      process,
      output,
      debugger: debugger,
      announcement: switch (usesStart) {
        true => VmServiceAnnouncement.serverpodProxy,
        false => VmServiceAnnouncement.dartVm,
      },
    );
    try {
      await debugger?.start();
      await context.launch.didStart(event);
    } catch (error) {
      logService.warn('Could not report the start of ${server.name}: $error');
    }
    onDidChange?.call();
    unawaited(_watchExit(running, output, forwarding));
    if (_stopRequested.contains(server.root)) await _stop(running);
  }

  Future<void> _forwardOutput(
    HostProcess process,
    LumideOutputChannel output, {
    required ServerDebugger? debugger,
    required VmServiceAnnouncement announcement,
  }) {
    final lines = LineBuffer();
    final writer = OutputWriter(output);
    return Future.wait([
      process.stdout.forEach((chunk) {
        writer.add(chunk);
        if (debugger == null || debugger.isAttached) return;
        for (final line in lines.add(chunk)) {
          if (announcement.webSocketUriIn(line) case final uri?) {
            unawaited(debugger.attach(uri));
            return;
          }
        }
      }),
      process.stderr.forEach(writer.add),
    ]).then((_) => writer.close());
  }

  /// Reports the end of [running] once its process exits, whatever fails
  /// on the way, so Lumide and the debugger never wait on a gone server.
  Future<void> _watchExit(
    _RunningServer running,
    LumideOutputChannel output,
    Future<void> forwarding,
  ) async {
    final exitCode = await running.process.exitCode;
    try {
      await forwarding;
      await output.appendLine('${running.server.name} stopped '
          '(exit code $exitCode).');
    } catch (error) {
      logService.warn('Could not finish the output: $error');
    } finally {
      if (identical(_running[running.server.root], running)) {
        _running.remove(running.server.root);
      }
      if (running.debugger case final debugger?) {
        _debugSessions.close(debugger);
        await debugger.end(message: '${running.server.name} stopped.');
      }
      await _endLaunch(running.event, exitCode: exitCode);
      onDidChange?.call();
    }
  }

  /// Stops [running], first letting go of it in the debugger, so a server
  /// paused on a breakpoint can shut down.
  ///
  /// A supervised server stops itself, escalating as needed; the process
  /// tree is only killed from here when the supervisor does not finish.
  Future<void> _stop(_RunningServer running) async {
    await running.debugger?.release();
    await running.process.stop(
      escalateAfter: switch (running.supervised) {
        true => _supervisedStopTimeout,
        false => const Duration(seconds: 3),
      },
      timeout: switch (running.supervised) {
        true => _supervisedStopTimeout + const Duration(seconds: 5),
        false => _stopTimeout,
      },
    );
  }

  /// The script servers run under, which stops them when Lumide goes
  /// away however it ends; null to run them directly when it is missing.
  Future<String?> _supervisor() async {
    final script = _supervisorScript ??= pluginFile(scriptSupervise);
    final found = await script;
    if (found == null) {
      logService.warn(
        'Cannot find $scriptSupervise; servers keep running if Lumide '
        'quits without stopping them.',
      );
    }
    return found;
  }

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
      kinds: _kinds,
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
      if (projectService.serverAt(serverRoot) case final server?) {
        return server;
      }
      // A server created since the last scan.
      await projectService.refresh();
      if (projectService.serverAt(serverRoot) case final server?) {
        return server;
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
    return _channels[server.root] ??= context.window
        .createOutputChannel('$channelServerpodServer: ${server.name}')
        .catchError((Object error) {
      _channels.remove(server.root);
      throw error;
    });
  }

  static const _kinds = [LumideLaunchKind.run, LumideLaunchKind.debug];

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
    required this.supervised,
    this.debugger,
  });

  final ServerPackage server;
  final HostProcess process;
  final LumideLaunchEvent event;
  final ServerLaunchOptions options;

  /// Whether the server runs with `serverpod start`.
  final bool usesStart;

  /// Whether the server runs under the plugin's supervisor script.
  final bool supervised;

  /// The debugger, when the server was started for debugging.
  final ServerDebugger? debugger;
}
