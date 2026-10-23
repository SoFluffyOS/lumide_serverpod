import 'dart:async';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';

/// Errors nobody awaited would end the plugin process, taking every
/// Serverpod feature with it, so they are logged instead.
void main() => runZonedGuarded(
      () => ServerpodPlugin().run(),
      (error, stackTrace) =>
          stderr.writeln('[ERROR] Uncaught: $error\n$stackTrace'),
    );

class ServerpodPlugin extends LumidePlugin {
  late LumideContext _context;
  late LogService logService;
  late ProcessHub processHub;
  late ProjectService projectService;
  late CliService cliService;
  late ServerpodService serverpodService;
  late ServerRunService runService;
  late StatusBarService statusBarService;
  late ToolsMenu toolsMenu;
  late GenerateOnSave generateOnSave;
  final List<LumideDisposable> _listeners = [];
  bool _initialized = false;
  bool _serverFeaturesActive = false;
  Future<void>? _refreshing;
  bool _refreshAgain = false;

  @override
  Future<void> onActivate(LumideContext context) async {
    _context = context;
    logService = LogService(log);
    processHub = ProcessHub(context.shell);
    projectService = ProjectService(context);
    cliService = CliService(context, processHub, logService);
    serverpodService = ServerpodService(context, projectService, cliService);
    runService = ServerRunService(
      context,
      projectService,
      cliService,
      processHub,
      logService,
    );
    statusBarService = StatusBarService(context);
    toolsMenu = ToolsMenu(
      context,
      isRunning: () => runService.runningServers.isNotEmpty,
    );
    generateOnSave = GenerateOnSave(
      serverRootFor: (filePath) => projectService.serverFor(filePath)?.root,
      shouldGenerate: _shouldGenerateOnSave,
      generate: (serverRoot) =>
          serverpodService.generateIn(serverRoot, revealOutput: false),
      readFile: _readFile,
    );
    _initialized = true;

    await _registerCommands(context);
    await projectService.refresh();
    runService.onDidChange = () => unawaited(_updateStatusBar());
    await runService.init();

    _listeners.addAll([
      context.workspace.onDidSaveTextDocument(
        (uri) => unawaited(generateOnSave.handleSave(uri)),
      ),
      context.workspace.onDidChangeWorkspaceFolders(
        (_) => _scheduleRefresh(),
      ),
      context.workspace.onDidChangeFiles(_handleFileChanges),
    ]);

    if (projectService.servers.isEmpty) {
      logService.info('No Serverpod server in this workspace.');
      return;
    }
    await _activateServerFeatures();
    logService.info('Serverpod plugin ready.');
  }

  /// Status bar, menus and the model language server, once the workspace
  /// has a server.
  Future<void> _activateServerFeatures() async {
    if (_serverFeaturesActive) return;
    _serverFeaturesActive = true;
    await Future.wait([
      _updateStatusBar(),
      _registerMenuActions(),
      _registerLanguageServer(),
    ]);
  }

  Future<void> _registerCommands(LumideContext context) async {
    final callbacks = <String, Future<void> Function(Map<String, dynamic>?)>{
      cmdServerpodStart: runService.start,
      cmdServerpodDebug: runService.debug,
      cmdServerpodStop: runService.stop,
      cmdServerpodGenerate: serverpodService.generate,
      cmdServerpodCreateMigration: serverpodService.createMigration,
      cmdServerpodCreateRepairMigration: serverpodService.createRepairMigration,
      cmdServerpodApplyMigrations: serverpodService.applyMigrations,
      cmdServerpodRunScript: serverpodService.runScript,
      cmdServerpodDockerUp: serverpodService.startDocker,
      cmdServerpodDockerStop: serverpodService.stopDocker,
      cmdServerpodCreate: serverpodService.createProject,
      cmdServerpodUpgrade: (_) => serverpodService.upgrade(),
      cmdServerpodTools: toolsMenu.show,
    };
    await Future.wait([
      for (final MapEntry(key: id, value: callback) in callbacks.entries)
        context.commands.registerCommand(
          id: id,
          title: serverpodCommandTitle(id),
          category: pluginName,
          callback: ([args]) => _guard(id, () => callback(args)),
        ),
    ]);
  }

  Future<void> _registerMenuActions() async {
    await Future.wait([
      _context.menus.registerAction(
        const LumideMenuAction(
          id: 'start_file_tree',
          title: 'Start Serverpod Server',
          command: cmdServerpodStart,
          location: LumideMenuLocation.fileTreeItem,
          group: 'serverpod',
          priority: 92,
        ),
      ),
      _context.menus.registerAction(
        const LumideMenuAction(
          id: 'generate_file_tree',
          title: 'Serverpod Generate',
          command: cmdServerpodGenerate,
          location: LumideMenuLocation.fileTreeItem,
          group: 'serverpod',
          priority: 91,
        ),
      ),
      _context.menus.registerAction(
        const LumideMenuAction(
          id: 'create_migration_file_tree',
          title: 'Create Serverpod Migration',
          command: cmdServerpodCreateMigration,
          location: LumideMenuLocation.fileTreeItem,
          group: 'serverpod',
          priority: 90,
        ),
      ),
    ]);
  }

  Future<void> _registerLanguageServer() async {
    final enabled = await _context.workspace
            .getConfiguration(confLanguageServer) as bool? ??
        defaultLanguageServer;
    if (!enabled) return;
    if (await cliService.version() == null) {
      logService.warn(
        'Serverpod CLI not found; model files are not checked. Install it '
        'with "dart pub global activate serverpod_cli".',
      );
      return;
    }
    await _context.languages.registerLanguageServer(
      id: languageServerServerpod,
      languageId: 'yaml',
      displayName: pluginName,
      iconPath: assetIconServerpodSolid,
      fileExtensions: modelFileExtensions,
      extensionLanguageMap: const {'.spy': 'yaml'},
      command: executableServerpod,
      args: const ['language-server'],
      runsPerFolder: true,
    );
  }

  Future<void> _updateStatusBar() async {
    if (!_serverFeaturesActive) return;
    try {
      await statusBarService.update(
        version: await cliService.version(),
        runningServers: runService.runningServers,
      );
    } catch (error) {
      logService.warn('Could not update the status bar: $error');
    }
  }

  Future<bool> _shouldGenerateOnSave(String serverRoot) async {
    if (runService.generatesCode(serverRoot)) return false;
    final enabled = await _context.workspace.getConfiguration(
      confGenerateOnSave,
      scope: Uri.file(serverRoot).toString(),
    );
    return enabled as bool? ?? defaultGenerateOnSave;
  }

  Future<String?> _readFile(String filePath) async {
    try {
      return await _context.fs.readString(filePath);
    } catch (_) {
      return null;
    }
  }

  void _handleFileChanges(LumideFileChangeEvent event) {
    final pubspecChanged = event.changes.any(
      (change) => change.uri.endsWith('pubspec.yaml'),
    );
    if (event.isOverflow || pubspecChanged) _scheduleRefresh();
  }

  /// Scans for servers again, at most once at a time.
  void _scheduleRefresh() {
    if (_refreshing != null) {
      _refreshAgain = true;
      return;
    }
    _refreshing = _refreshServers().whenComplete(() {
      _refreshing = null;
      if (!_refreshAgain) return;
      _refreshAgain = false;
      _scheduleRefresh();
    });
  }

  Future<void> _refreshServers() async {
    try {
      final servers = await projectService.refresh();
      await runService.refreshConfigurations();
      if (servers.isNotEmpty) await _activateServerFeatures();
    } catch (error, stackTrace) {
      logService.error(
          'Could not refresh Serverpod servers', error, stackTrace);
    }
  }

  Future<void> _guard(String command, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      logService.error('$command failed', error, stackTrace);
      await _context.window.showMessage(
        '${serverpodCommandTitle(command)} failed: $error',
        type: MessageType.error,
        title: pluginName,
      );
    }
  }

  @override
  Future<void> onDeactivate() async {
    if (!_initialized) return;
    for (final listener in _listeners) {
      listener.dispose();
    }
    _listeners.clear();
    generateOnSave.dispose();
    await _disposeSafely('run service', runService.dispose);
    await _disposeSafely('status bar', statusBarService.dispose);
    processHub.dispose();
  }

  Future<void> _disposeSafely(
    String name,
    Future<void> Function() dispose,
  ) async {
    try {
      await dispose();
    } catch (error, stackTrace) {
      logService.error('Failed to dispose $name', error, stackTrace);
    }
  }
}
