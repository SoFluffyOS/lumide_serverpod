import 'dart:io';
import 'dart:isolate';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:path/path.dart' as path;

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
        iconPath: await _logoPath(),
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

  /// The absolute path of the Serverpod logo; the status bar does not
  /// resolve paths relative to the plugin.
  static Future<String?> _logoPath() async {
    final candidates = <String>[];
    try {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:lumide_serverpod/lumide_serverpod.dart'),
      );
      if (library != null && library.isScheme('file')) {
        final packageRoot = path.dirname(path.dirname(library.toFilePath()));
        candidates.add(path.join(packageRoot, assetIconServerpodSolid));
      }
    } catch (_) {
      // Running from a snapshot without a package config.
    }
    final scriptDirectory = path.dirname(Platform.script.toFilePath());
    candidates.addAll([
      path.join(scriptDirectory, '..', assetIconServerpodSolid),
      path.join(Directory.current.path, assetIconServerpodSolid),
    ]);

    for (final candidate in candidates) {
      final normalized = path.normalize(candidate);
      if (await File(normalized).exists()) return normalized;
    }
    return null;
  }

  Future<void> dispose() async {
    if (!_created) return;
    _created = false;
    await context.statusBar.disposeItem(_itemId);
  }
}
