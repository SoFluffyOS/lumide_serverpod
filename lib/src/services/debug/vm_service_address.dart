import 'package:vm_service/utils.dart';

/// Where a debugged server's VM service is announced in its output.
enum VmServiceAnnouncement {
  /// `serverpod start` puts a proxy in front of the server's VM service. It
  /// keeps its address when the server restarts, and runs code generation
  /// before reloads.
  serverpodProxy,

  /// `dart --enable-vm-service` prints the server's own VM service.
  dartVm;

  RegExp get _pattern => switch (this) {
        serverpodProxy => RegExp(r'VM service proxy listening on (\S+)'),
        dartVm => RegExp(r'The Dart VM service is listening on (\S+)'),
      };

  /// The WebSocket address [line] announces, or null when it announces none.
  String? webSocketUriIn(String line) {
    final address = _pattern.firstMatch(line)?.group(1);
    if (address == null) return null;
    final uri = Uri.tryParse(address);
    if (uri == null || !uri.hasScheme) return null;
    return convertToWebSocketUrl(serviceProtocolUrl: uri).toString();
  }
}

/// Splits streamed output into whole lines.
class LineBuffer {
  final StringBuffer _partial = StringBuffer();

  /// The lines [chunk] completes. A trailing partial line waits for the
  /// next chunk.
  List<String> add(String chunk) {
    _partial.write(chunk);
    final text = _partial.toString();
    final lastBreak = text.lastIndexOf('\n');
    if (lastBreak < 0) return const [];

    _partial
      ..clear()
      ..write(text.substring(lastBreak + 1));
    return [
      for (final line in text.substring(0, lastBreak).split('\n'))
        switch (line.endsWith('\r')) {
          true => line.substring(0, line.length - 1),
          false => line,
        },
    ];
  }
}
