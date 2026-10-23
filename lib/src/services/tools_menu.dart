import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/commands.dart';
import 'package:lumide_serverpod/src/constants.dart';

/// The Serverpod tools as one quick pick, opened from the status bar.
class ToolsMenu {
  ToolsMenu(this.context, {required this.isRunning});

  final LumideContext context;
  final bool Function() isRunning;

  Future<void> show([Map<String, dynamic>? args]) async {
    final running = isRunning();
    final selected = await context.window.showQuickPick(
      [
        _item(cmdServerpodStart, iconPlay),
        if (running) _item(cmdServerpodStop, iconStop),
        _item(cmdServerpodGenerate, iconCode),
        _item(cmdServerpodCreateMigration, iconDatabase),
        _item(cmdServerpodApplyMigrations, iconDatabaseZap),
        _item(cmdServerpodCreateRepairMigration, iconWrench),
        _item(cmdServerpodRunScript, iconTerminal),
        _item(cmdServerpodDockerUp, iconContainer),
        _item(cmdServerpodDockerStop, iconContainer),
        _item(cmdServerpodCreate, iconFolderPlus),
        _item(cmdServerpodUpgrade, iconUpgrade),
      ],
      placeholder: 'Serverpod',
      position: switch (args?['position']) {
        final Map position => position.cast<String, int>(),
        _ => null,
      },
    );
    final command = selected?.payload;
    if (command is! String) return;
    await context.commands.executeCommand(command);
  }

  static QuickPickItem _item(String command, String icon) {
    final title = serverpodCommandTitle(command);
    return QuickPickItem(
      label: title.substring(title.indexOf(':') + 1).trim(),
      payload: command,
      icon: icon,
    );
  }
}
