import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/src/constants.dart';
import 'package:lumide_serverpod/src/models/models.dart';
import 'package:lumide_serverpod/src/services/log_service.dart';
import 'package:lumide_serverpod/src/services/output_writer.dart';
import 'package:lumide_serverpod/src/services/process_hub.dart';

/// Runs the Serverpod CLI and other tools, with their output in the
/// Serverpod output channel.
class CliService {
  CliService(this.context, this.processHub, this.logService);

  final LumideContext context;
  final ProcessHub processHub;
  final LogService logService;

  Future<ServerpodVersion?>? _version;
  Future<LumideOutputChannel>? _channel;

  /// The installed CLI's version, or null when it is not installed.
  Future<ServerpodVersion?> version({bool refresh = false}) {
    if (refresh) _version = null;
    return _version ??= _lookUpVersion();
  }

  /// Runs the Serverpod CLI [arguments] like [run]. Serverpod 4 runs
  /// without prompts, taking answers from options instead.
  Future<bool> runServerpod(
    List<String> arguments, {
    required String title,
    required String workingDirectory,
    bool revealOutput = true,
  }) async {
    final installed = await version();
    final interactive = installed == null || installed.major < 4;
    return run(
      [if (!interactive) '--no-interactive', ...arguments],
      title: title,
      workingDirectory: workingDirectory,
      executable: executableServerpod,
      isServerpod: true,
      revealOutput: revealOutput,
    );
  }

  Future<LumideOutputChannel> channel() =>
      _channel ??= context.window.createOutputChannel(channelServerpod);

  /// Runs [executable] in [workingDirectory] with cancellable progress
  /// titled [title], and reports a failure. Returns whether it succeeded.
  Future<bool> run(
    List<String> arguments, {
    required String title,
    required String workingDirectory,
    required String executable,
    bool isServerpod = false,
    bool revealOutput = true,
  }) async {
    final output = await channel();
    if (revealOutput) await output.show(preserveFocus: true);
    await output.appendLine('> $executable ${arguments.join(' ')}');
    await output.appendLine('  in $workingDirectory');

    final exitCode = await context.window.withProgress<int?>(
      title: title,
      cancellable: true,
      task: (progress) => _stream(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        output: output,
        progress: progress,
      ),
    );

    if (exitCode == 0) {
      await output.appendLine('$title finished.\n');
      return true;
    }

    await output.appendLine(switch (exitCode) {
      null => '$title could not start.\n',
      _ => '$title failed with exit code $exitCode.\n',
    });
    await context.window.showMessage(
      switch (exitCode) {
        null when isServerpod =>
          '$title failed: the Serverpod CLI was not found. Install it with '
              '"dart pub global activate serverpod_cli".',
        _ => '$title failed. See the Serverpod output for details.',
      },
      type: MessageType.error,
      title: pluginName,
    );
    return false;
  }

  Future<int?> _stream(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required LumideOutputChannel output,
    required LumideProgress progress,
  }) async {
    final HostProcess process;
    try {
      process = await processHub.spawn(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    } catch (error) {
      logService.error('Could not start $executable', error);
      await output.appendLine('[ERROR] $error');
      return null;
    }

    final cancelListener = progress.onCancel(
      () => unawaited(process.stop()),
    );
    final writer = OutputWriter(output);
    final forwarding = Future.wait([
      process.stdout.forEach(writer.add),
      process.stderr.forEach(writer.add),
    ]).then((_) => writer.close());
    try {
      final exitCode = await process.exitCode;
      await forwarding;
      return exitCode;
    } finally {
      cancelListener.dispose();
    }
  }

  Future<ServerpodVersion?> _lookUpVersion() async {
    try {
      final result =
          await context.shell.run(executableServerpod, const ['version']);
      final version =
          ServerpodVersion.parse('${result.stdout}\n${result.stderr}');
      if (version == null) {
        logService.warn('Could not read the Serverpod CLI version.');
      }
      return version;
    } catch (error) {
      logService.warn('Serverpod CLI not found: $error');
      return null;
    }
  }
}
