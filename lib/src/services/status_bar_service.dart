import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';

/// The Serverpod item in the status bar: the CLI version, the servers
/// running, and the tools menu on click.
class StatusBarService {
  StatusBarService(this.context);

  final LumideContext context;

  static const String _itemId = 'serverpod.status';

  bool _created = false;

  Future<void> update({
    required ServerpodVersion? version,
    required List<String> runningServers,
  }) async {
    final text = runningServers.join(', ');
    final tooltip = switch (version) {
      null => 'Serverpod CLI not found',
      final installed => 'Serverpod $installed',
    };
    if (!_created) {
      _created = true;
      await context.statusBar.createItem(
        id: _itemId,
        text: text,
        tooltip: tooltip,
        command: cmdServerpodTools,
        iconName: iconServer,
        alignment: 'right',
        priority: 97,
      );
      return;
    }
    await context.statusBar.updateItem(
      _itemId,
      text: text,
      tooltip: tooltip,
      command: cmdServerpodTools,
    );
  }

  Future<void> dispose() async {
    if (!_created) return;
    _created = false;
    await context.statusBar.disposeItem(_itemId);
  }
}
