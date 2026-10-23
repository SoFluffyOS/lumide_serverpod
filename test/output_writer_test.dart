import 'dart:async';

import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

void main() {
  const interval = Duration(milliseconds: 10);

  Future<void> settle() => Future<void>.delayed(interval * 4);

  test('sends a burst of chunks as one append', () async {
    final output = FakeOutput('server');
    final writer = OutputWriter(output, interval: interval);

    for (var index = 0; index < 1000; index++) {
      writer.add('line $index\n');
    }
    await settle();

    expect(output.appends, 1);
    expect(output.text.toString(), startsWith('line 0\nline 1\n'));
    expect(output.text.toString(), endsWith('line 999\n'));
  });

  test('waits for each append before sending the next', () async {
    final output = _SlowOutput();
    final writer = OutputWriter(output, interval: interval);

    writer.add('a');
    await settle();
    writer.add('b');
    await settle();
    expect(output.calls, ['a']);

    output.finish();
    await settle();
    expect(output.calls, ['a', 'b']);
  });

  test('drops output past the limit and says how much', () async {
    final output = FakeOutput('server');
    final writer = OutputWriter(output, interval: interval, maxPending: 10)
      ..add('12345')
      ..add('67890')
      ..add('dropped');
    await writer.close();

    expect(
      output.text.toString(),
      '1234567890\n[7 characters of output dropped]\n',
    );
  });

  test('close sends what is left right away', () async {
    final output = FakeOutput('server');
    final writer = OutputWriter(output, interval: const Duration(hours: 1))
      ..add('last words');
    await writer.close();

    expect(output.text.toString(), 'last words');
  });

  test('ignores a channel Lumide closed', () async {
    final output = FakeOutput('server')..closed = true;
    final writer = OutputWriter(output, interval: interval)..add('lost');

    await writer.close();
  });
}

class _SlowOutput extends FakeOutput {
  _SlowOutput() : super('slow');

  final calls = <String>[];
  Completer<void> _pending = Completer<void>();

  void finish() {
    _pending.complete();
    _pending = Completer<void>();
  }

  @override
  Future<void> append(String value) {
    calls.add(value);
    return _pending.future;
  }
}
