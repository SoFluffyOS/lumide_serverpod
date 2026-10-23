import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:lumide_serverpod/src/services/cli_service.dart';
import 'package:lumide_serverpod/src/services/project_service.dart';
import 'package:path/path.dart' as path;

/// The Serverpod tools: code generation, migrations, scripts, Docker and
/// new projects.
class ServerpodService {
  ServerpodService(this.context, this.projectService, this.cliService);

  final LumideContext context;
  final ProjectService projectService;
  final CliService cliService;

  Future<void> generate([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    await generateIn(server.root);
  }

  /// Generates code for the server in [serverRoot]. Used after saves, so it
  /// only shows the output when generation fails.
  Future<bool> generateIn(String serverRoot, {bool revealOutput = true}) async {
    return cliService.runServerpod(
      ['generate'],
      title: 'Generating ${path.basename(serverRoot)}',
      workingDirectory: serverRoot,
      revealOutput: revealOutput,
    );
  }

  Future<void> createMigration([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;

    final kind = await context.window.showQuickPick(
      const [
        QuickPickItem(
          label: 'Migration',
          description: 'From the latest migration to the current models',
          payload: '',
          icon: iconDatabase,
        ),
        QuickPickItem(
          label: 'Empty Migration',
          description: 'Even when no model changed (--empty)',
          payload: '--empty',
          icon: iconDatabase,
        ),
        QuickPickItem(
          label: 'Forced Migration',
          description: 'Even when it may destroy data (--force)',
          payload: '--force',
          icon: iconDatabaseZap,
        ),
      ],
      placeholder: 'Create a migration for ${server.name}',
    );
    final flag = kind?.payload;
    if (flag is! String) return;

    final tag = await _askTag();
    if (tag == null) return;

    await cliService.runServerpod(
      [
        'create-migration',
        if (flag.isNotEmpty) flag,
        if (tag.isNotEmpty) ...['--tag', tag],
      ],
      title: 'Creating a migration for ${server.name}',
      workingDirectory: server.root,
    );
  }

  Future<void> createRepairMigration([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;

    final mode = await _pickRunMode(
      'Repair the database of which run mode?',
    );
    if (mode == null) return;

    final tag = await _askTag();
    if (tag == null) return;

    await cliService.runServerpod(
      [
        'create-repair-migration',
        '--mode',
        mode,
        if (tag.isNotEmpty) ...['--tag', tag],
      ],
      title: 'Creating a repair migration for ${server.name}',
      workingDirectory: server.root,
    );
  }

  /// Applies pending migrations with the server's maintenance role, which
  /// exits once they are applied.
  Future<void> applyMigrations([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;

    final mode = await _configuredRunMode(server);
    if (mode != defaultRunMode) {
      final confirmed = await context.window.showConfirmDialog(
        'Apply the pending migrations of ${server.name} to the $mode '
        'database?',
        title: 'Apply Migrations',
      );
      if (!confirmed) return;
    }

    await cliService.run(
      [
        'bin/main.dart',
        '--mode',
        mode,
        '--role',
        'maintenance',
        '--apply-migrations',
      ],
      title: 'Applying migrations to ${server.name} ($mode)',
      workingDirectory: server.root,
      executable: executableDart,
    );
  }

  Future<void> runScript([Map<String, dynamic>? args]) async {
    await projectService.refresh();
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    if (server.scripts.isEmpty) {
      await context.window.showMessage(
        '${server.name} has no scripts. Add them under serverpod: scripts: '
        'in its pubspec.yaml.',
        title: pluginName,
      );
      return;
    }

    final selected = await context.window.showQuickPick(
      [
        for (final script in server.scripts)
          QuickPickItem(label: script, payload: script, icon: iconTerminal),
      ],
      placeholder: 'Run a script of ${server.name}',
    );
    final script = selected?.payload;
    if (script is! String) return;

    await cliService.runServerpod(
      ['run', script],
      title: 'Running $script',
      workingDirectory: server.root,
    );
  }

  Future<void> startDocker([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    await cliService.run(
      const ['compose', 'up', '--build', '--detach'],
      title: 'Starting Docker services of ${server.name}',
      workingDirectory: server.root,
      executable: executableDocker,
    );
  }

  Future<void> stopDocker([Map<String, dynamic>? args]) async {
    final server = await projectService.pickServer(args: args);
    if (server == null) return;
    await cliService.run(
      const ['compose', 'stop'],
      title: 'Stopping Docker services of ${server.name}',
      workingDirectory: server.root,
      executable: executableDocker,
    );
  }

  Future<void> createProject([Map<String, dynamic>? args]) async {
    final name = await context.window.showInputBox(
      title: 'New Serverpod Project',
      prompt: 'Project name: lowercase letters, digits and underscores',
      placeHolder: 'my_project',
    );
    if (name == null || name.isEmpty) return;
    if (!_projectNamePattern.hasMatch(name)) {
      await context.window.showMessage(
        '"$name" is not a valid project name. Use lowercase letters, digits '
        'and underscores, starting with a letter.',
        type: MessageType.error,
        title: pluginName,
      );
      return;
    }

    final installed = await cliService.version();
    final template = await _pickTemplate(installed);
    if (template == null) return;

    final folder = await context.window.showOpenFolderDialog(
      title: 'Create $name in',
      defaultPath: await projectService.targetFolder(args),
    );
    if (folder == null) return;

    final created = await cliService.runServerpod(
      [
        'create',
        name,
        '--template',
        template,
      ],
      title: 'Creating $name',
      workingDirectory: folder,
    );
    if (!created) return;

    await context.window.showMessage(
      'Created $name in ${path.join(folder, name)}.',
      title: pluginName,
    );
    await projectService.refresh();
  }

  Future<void> upgrade() async {
    final installed = await cliService.version();
    final workingDirectory = await projectService.targetFolder(null) ??
        await context.workspace.getPluginStorageDir();
    const title = 'Upgrading the Serverpod CLI';
    if (installed != null && installed.major >= 4) {
      await cliService.runServerpod(
        const ['upgrade'],
        title: title,
        workingDirectory: workingDirectory,
      );
    } else {
      await cliService.run(
        const ['pub', 'global', 'activate', 'serverpod_cli'],
        title: title,
        workingDirectory: workingDirectory,
        executable: executableDart,
      );
    }
    await cliService.version(refresh: true);
  }

  Future<String> _configuredRunMode(ServerPackage server) async {
    final mode = await context.workspace.getConfiguration(
      confRunMode,
      scope: Uri.file(server.root).toString(),
    );
    if (mode is String && runModes.contains(mode)) return mode;
    return defaultRunMode;
  }

  Future<String?> _pickRunMode(String placeholder) async {
    final selected = await context.window.showQuickPick(
      [
        for (final mode in runModes)
          QuickPickItem(label: mode, payload: mode, icon: iconDatabase),
      ],
      placeholder: placeholder,
    );
    final mode = selected?.payload;
    if (mode is! String) return null;
    return mode;
  }

  Future<String?> _pickTemplate(ServerpodVersion? installed) async {
    final supportsFullstack = installed?.supportsStart ?? true;
    final selected = await context.window.showQuickPick(
      [
        if (supportsFullstack)
          const QuickPickItem(
            label: 'Full Stack',
            description: 'A server and a companion Flutter app',
            payload: 'fullstack',
            icon: iconFolderPlus,
          ),
        const QuickPickItem(
          label: 'Server',
          description: 'A server and its client package',
          payload: 'server',
          icon: iconServer,
        ),
        const QuickPickItem(
          label: 'Module',
          description: 'A module other Serverpod projects can use',
          payload: 'module',
          icon: iconFolderPlus,
        ),
        if (!supportsFullstack)
          const QuickPickItem(
            label: 'Mini',
            description: 'A server without a database',
            payload: 'mini',
            icon: iconFolderPlus,
          ),
      ],
      placeholder: 'Choose a template',
    );
    final template = selected?.payload;
    if (template is! String) return null;
    return template;
  }

  /// An optional migration tag; empty for none, null when cancelled.
  Future<String?> _askTag() async {
    while (true) {
      final tag = await context.window.showInputBox(
        title: 'Migration Tag',
        prompt: 'Optional: lowercase letters, digits and dashes',
        placeHolder: 'add-users',
      );
      if (tag == null) return null;
      final trimmed = tag.trim();
      if (trimmed.isEmpty || _tagPattern.hasMatch(trimmed)) return trimmed;
      await context.window.showMessage(
        'Tags can only contain lowercase letters, digits and dashes.',
        type: MessageType.error,
        title: pluginName,
      );
    }
  }

  static final _projectNamePattern = RegExp(r'^[a-z][a-z0-9_]*$');
  static final _tagPattern = RegExp(r'^[a-z0-9-]+$');
}
