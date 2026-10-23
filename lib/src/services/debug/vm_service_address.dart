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
///
/// A line longer than [maxLineLength] keeps only its start, which is where
/// an announcement would be; output without line breaks, such as progress
/// redrawn with carriage returns, cannot grow it without limit.
class LineBuffer {
  LineBuffer({this.maxLineLength = 64 * 1024});

  final int maxLineLength;
  String _partial = '';

  /// The lines [chunk] completes. A trailing partial line waits for the
  /// next chunk.
  List<String> add(String chunk) {
    final firstBreak = chunk.indexOf('\n');
    if (firstBreak < 0) {
      _keep(chunk);
      return const [];
    }

    _keep(chunk.substring(0, firstBreak));
    final completed = _partial;
    final lastBreak = chunk.lastIndexOf('\n');
    final whole = switch (lastBreak > firstBreak) {
      true => chunk.substring(firstBreak + 1, lastBreak).split('\n'),
      false => const <String>[],
    };
    _partial = '';
    _keep(chunk.substring(lastBreak + 1));
    return [
      for (final line in [completed, ...whole])
        switch (line.endsWith('\r')) {
          true => line.substring(0, line.length - 1),
          false => line,
        },
    ];
  }

  void _keep(String text) {
    final room = maxLineLength - _partial.length;
    if (room <= 0) return;
    _partial += switch (text.length > room) {
      true => text.substring(0, room),
      false => text,
    };
  }
}
