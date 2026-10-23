import 'package:lumide_serverpod/src/constants.dart';

/// Titles for every command the plugin registers, keyed by command id.
///
/// `plugin.yaml` must list the same commands with the same titles;
/// `test/commands_manifest_test.dart` enforces it.
const Map<String, String> serverpodCommandTitles = {
  cmdServerpodStart: 'Serverpod: Start Server',
  cmdServerpodStop: 'Serverpod: Stop Server',
  cmdServerpodGenerate: 'Serverpod: Generate Code',
  cmdServerpodCreateMigration: 'Serverpod: Create Migration',
  cmdServerpodCreateRepairMigration: 'Serverpod: Create Repair Migration',
  cmdServerpodApplyMigrations: 'Serverpod: Apply Migrations',
  cmdServerpodRunScript: 'Serverpod: Run Script',
  cmdServerpodDockerUp: 'Serverpod: Start Docker Services',
  cmdServerpodDockerStop: 'Serverpod: Stop Docker Services',
  cmdServerpodCreate: 'Serverpod: New Project',
  cmdServerpodUpgrade: 'Serverpod: Upgrade CLI',
  cmdServerpodTools: 'Serverpod: Tools Menu',
};

/// Title of a registered command, falling back to its id.
String serverpodCommandTitle(String id) => serverpodCommandTitles[id] ?? id;
