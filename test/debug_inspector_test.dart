import 'dart:async';
import 'dart:convert';

import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

const _isolate = 'isolates/1';
const _listLength = 250;

void main() {
  late _ListVm vm;
  late DebugInspector inspector;

  setUp(() {
    vm = _ListVm();
    inspector = DebugInspector();
  });

  tearDown(() => vm.close());

  Future<int> listReference() async {
    final frames = await inspector.stackFrames(vm.service, _isolate);
    final locals = await inspector.variables(
      vm.service,
      _isolate,
      frames.single.id,
    );
    final reference = locals.single.variablesReference;
    if (reference == null) fail('The list cannot be expanded');
    return reference;
  }

  test('loads a long list one page at a time', () async {
    final firstPage = await inspector.variables(
      vm.service,
      _isolate,
      await listReference(),
    );

    expect(vm.requestedPages, [(0, DebugInspector.pageSize)]);
    expect(firstPage, hasLength(DebugInspector.pageSize + 1));
    expect(firstPage.first.name, '[0]');
    expect(firstPage.last.name, '[100…249]');
    expect(firstPage.last.value, '150 more');

    final secondPage = await inspector.variables(
      vm.service,
      _isolate,
      firstPage.last.variablesReference ?? -1,
    );
    expect(secondPage.first.name, '[100]');
    expect(secondPage.last.name, '[200…249]');

    final lastPage = await inspector.variables(
      vm.service,
      _isolate,
      secondPage.last.variablesReference ?? -1,
    );
    expect(lastPage, hasLength(50));
    expect(lastPage.last.name, '[249]');
  });

  test('keeps expanded variables when the stack loads again', () async {
    final reference = await listReference();
    await inspector.stackFrames(vm.service, _isolate);

    final elements = await inspector.variables(vm.service, _isolate, reference);

    expect(elements, isNotEmpty);
  });
}

/// A paused isolate with one local: a list of [_listLength] integers.
class _ListVm {
  _ListVm() {
    service = VmService(_incoming.stream, _handle);
  }

  final _incoming = StreamController<String>();
  late final VmService service;
  final requestedPages = <(int?, int?)>[];

  Future<void> close() async {
    await service.dispose();
    await _incoming.close();
  }

  void _handle(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    final params = request['params'] as Map<String, dynamic>? ?? const {};
    final result = switch (request['method']) {
      'getStack' => {
          'type': 'Stack',
          'frames': [_frame],
          'messages': <Object>[],
        },
      'getObject' => _list(params['offset'] as int?, params['count'] as int?),
      _ => {'type': 'Success'},
    };
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  Map<String, Object?> _list(int? offset, int? count) {
    requestedPages.add((offset, count));
    final start = offset ?? 0;
    final end = switch (count) {
      final count? when start + count < _listLength => start + count,
      _ => _listLength,
    };
    return {
      ..._listRef,
      'type': 'Instance',
      'offset': offset,
      'count': count,
      'elements': [for (var index = start; index < end; index++) _int(index)],
    };
  }

  static Map<String, Object?> _int(int value) => {
        'type': '@Instance',
        'kind': 'Int',
        'id': 'objects/int-$value',
        'valueAsString': '$value',
        'class': {'type': '@Class', 'id': 'classes/int', 'name': 'int'},
      };

  static const _listRef = {
    'type': '@Instance',
    'kind': 'List',
    'id': 'objects/list',
    'length': _listLength,
    'class': {'type': '@Class', 'id': 'classes/list', 'name': 'List'},
  };

  static const _frame = {
    'type': 'Frame',
    'index': 0,
    'function': {
      'type': '@Function',
      'id': 'functions/hello',
      'name': 'hello',
      'owner': {'type': '@Library', 'id': 'libraries/1', 'name': '', 'uri': ''},
      'static': false,
      'const': false,
      'implicit': false,
      'abstract': false,
      'isGetter': false,
      'isSetter': false,
    },
    'location': {
      'type': 'SourceLocation',
      'script': {
        'type': '@Script',
        'id': 'scripts/1',
        'uri': 'file:///app/app_server/lib/src/greeting_endpoint.dart',
      },
      'tokenPos': 0,
      'line': 12,
      'column': 3,
    },
    'vars': [
      {
        'type': 'BoundVariable',
        'name': 'items',
        'value': _listRef,
        'declarationTokenPos': 0,
        'scopeStartTokenPos': 0,
        'scopeEndTokenPos': 0,
      },
    ],
  };
}
