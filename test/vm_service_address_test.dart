import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

void main() {
  group('VmServiceAnnouncement', () {
    test('reads the proxy serverpod start announces', () {
      expect(
        VmServiceAnnouncement.serverpodProxy.webSocketUriIn(
          'VM service proxy listening on http://127.0.0.1:60077/w3nN5p-I=/',
        ),
        'ws://127.0.0.1:60077/w3nN5p-I=/ws',
      );
    });

    test('ignores the server process VM service behind the proxy', () {
      expect(
        VmServiceAnnouncement.serverpodProxy.webSocketUriIn(
          'The Dart VM service is listening on http://127.0.0.1:60073/Vy=/',
        ),
        isNull,
      );
    });

    test('reads the VM service dart announces', () {
      expect(
        VmServiceAnnouncement.dartVm.webSocketUriIn(
          'The Dart VM service is listening on http://127.0.0.1:8181/abc=/',
        ),
        'ws://127.0.0.1:8181/abc=/ws',
      );
    });

    test('returns null for other lines', () {
      expect(
        VmServiceAnnouncement.dartVm.webSocketUriIn('Server running.'),
        isNull,
      );
    });
  });

  group('LineBuffer', () {
    test('joins lines split across chunks', () {
      final buffer = LineBuffer();

      expect(buffer.add('VM service proxy list'), isEmpty);
      expect(buffer.add('ening on http://a/\nServer'), [
        'VM service proxy listening on http://a/',
      ]);
      expect(buffer.add(' running.\r\n\n'), ['Server running.', '']);
    });
  });

  group('debug command', () {
    test('serves the VM service and waits at the start with dart', () {
      final command = const ServerLaunchOptions().command(null, debug: true);

      expect(command.executable, 'dart');
      expect(command.arguments, [
        '--enable-vm-service=0',
        '--pause-isolates-on-start',
        'bin/main.dart',
        '--mode',
        'development',
      ]);
    });

    test('keeps serverpod start as it is, since it serves a VM service', () {
      const options = ServerLaunchOptions();
      const version = ServerpodVersion(4, 0, 4);

      expect(
        options.command(version, debug: true).arguments,
        options.command(version).arguments,
      );
    });
  });
}
