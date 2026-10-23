@TestOn('posix')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  /// Starts `sleep` under the supervisor, as the plugin starts a server.
  Future<Process> supervisedSleep() async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['bin/supervise.dart', 'sh', '-c', 'echo started; exec sleep 30'],
    );
    await process.stdout
        .transform(utf8.decoder)
        .firstWhere((chunk) => chunk.contains('started'));
    return process;
  }

  test('stops the server when Lumide goes away and closes its stdin', () async {
    final process = await supervisedSleep();

    await process.stdin.close();

    expect(
      await process.exitCode.timeout(const Duration(seconds: 10)),
      isNot(0),
    );
  });

  test('stops the server on an interrupt', () async {
    final process = await supervisedSleep();

    process.kill(ProcessSignal.sigint);

    expect(
      await process.exitCode.timeout(const Duration(seconds: 10)),
      isNot(0),
    );
  });

  test('passes on the server exit code', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['bin/supervise.dart', 'sh', '-c', 'exit 3'],
    );

    expect(result.exitCode, 3);
  });
}
