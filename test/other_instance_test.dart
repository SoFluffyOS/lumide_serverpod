import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

void main() {
  late FakeHost host;
  late OtherInstance otherInstance;

  setUp(() {
    host = FakeHost();
    otherInstance = OtherInstance(
      host.shell,
      pollInterval: Duration.zero,
      timeout: const Duration(milliseconds: 200),
    );
  });

  test('interrupts the CLI the server and its compiler run under', () async {
    host.shell.answers
      ..['pgrep'] = ['10\n11\n', '']
      ..['ps'] = [' 10  9\n 11  9\n'];

    expect(await otherInstance.stop('/work/app/app_server'), isTrue);
    expect(host.shell.ran, contains(equals(['kill', '-INT', '9'])));
    expect(
      host.shell.ran.first,
      [
        'pgrep',
        '-f',
        r'/work/app/app_server/\.dart_tool/serverpod/server\.dill'
      ],
    );
  });

  test('interrupts the server itself once its CLI is gone', () async {
    host.shell.answers
      ..['pgrep'] = ['10\n', '']
      ..['ps'] = [' 10  1\n'];

    expect(await otherInstance.stop('/work/app/app_server'), isTrue);
    expect(host.shell.ran, contains(equals(['kill', '-INT', '10'])));
  });

  test('reports an instance that keeps running', () async {
    host.shell.answers
      ..['pgrep'] = ['10\n']
      ..['ps'] = [' 10  9\n'];

    expect(await otherInstance.stop('/work/app/app_server'), isFalse);
  });

  test('has nothing to do when no other instance runs', () async {
    expect(await otherInstance.stop('/work/app/app_server'), isTrue);
    expect(host.shell.ran.where((command) => command.first == 'kill'), isEmpty);
  });

  test('escapes paths for pgrep', () {
    expect(
      OtherInstance.escapeRegExp('/a (b)/c+d.dill'),
      r'/a \(b\)/c\+d\.dill',
    );
  });
}
