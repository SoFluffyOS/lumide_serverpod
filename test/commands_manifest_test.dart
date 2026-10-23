import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

void main() {
  final manifest = LumideManifest.fromYaml(
    File('plugin.yaml').readAsStringSync(),
  );

  test('plugin.yaml lists every command with its runtime title', () {
    final manifestTitles = {
      for (final command in manifest.commands) command.id: command.title,
    };

    expect(manifestTitles, serverpodCommandTitles);
  });

  test('command titles are unique', () {
    final titles = serverpodCommandTitles.values.toList();
    expect(titles.toSet().length, titles.length);
  });

  test('every onCommand activation names a command', () {
    for (final event in manifest.activationEvents) {
      if (!event.startsWith('onCommand:')) continue;
      expect(serverpodCommandTitles, contains(event.substring(10)));
    }
  });

  test('settings match the plugin defaults', () {
    final defaults = {
      for (final property in manifest.configuration)
        property.key: property.defaultValue,
    };

    expect(defaults, {
      confGenerateOnSave: defaultGenerateOnSave,
      confRunMode: defaultRunMode,
      confApplyMigrationsOnStart: defaultApplyMigrationsOnStart,
      confLaunchFlutterApps: defaultLaunchFlutterApps,
      confLanguageServer: defaultLanguageServer,
    });
  });
}
