import 'dart:async';

import 'package:lumide_api/lumide_api.dart';

/// Writes process output to an output channel in batches.
///
/// Every append is a request to Lumide, and servers can print thousands of
/// chunks a second. Chunks are collected for [interval] and sent together,
/// one request at a time. When Lumide falls more than [maxPending]
/// characters behind, further output is dropped and a note says how much.
class OutputWriter {
  OutputWriter(
    this._output, {
    this.interval = const Duration(milliseconds: 50),
    this.maxPending = 1 << 20,
  });

  final LumideOutputChannel _output;
  final Duration interval;
  final int maxPending;

  final StringBuffer _pending = StringBuffer();
  int _dropped = 0;
  Timer? _timer;
  Future<void>? _inFlight;

  void add(String text) {
    if (_pending.length + text.length > maxPending) {
      _dropped += text.length;
      return;
    }
    _pending.write(text);
    _timer ??= Timer(interval, _flush);
  }

  /// Sends what is left once the previous request is done.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _inFlight;
    await _send();
  }

  void _flush() {
    _timer = null;
    if (_inFlight != null) {
      _timer = Timer(interval, _flush);
      return;
    }
    unawaited(_send());
  }

  Future<void> _send() async {
    if (_pending.isEmpty && _dropped == 0) return;
    final text = StringBuffer()..write(_pending);
    if (_dropped > 0) {
      text.write('\n[$_dropped characters of output dropped]\n');
    }
    _pending.clear();
    _dropped = 0;

    final request = _output.append(text.toString()).catchError((Object _) {
      // Lumide closed the channel; there is nowhere left to write.
    });
    _inFlight = request;
    await request;
    _inFlight = null;
  }
}
